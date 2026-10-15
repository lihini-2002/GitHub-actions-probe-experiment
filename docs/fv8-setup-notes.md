# FV8 setup notes

Workflows: [`fv8-probe.yml`](../.github/workflows/fv8-probe.yml) (FV8) and
[`fv8-control-probe.yml`](../.github/workflows/fv8-control-probe.yml) (matched control).
Both run the shared job [`fv8-node-experiment.yml`](../.github/workflows/fv8-node-experiment.yml).
Scripts: [`experiments/fv8/`](../experiments/fv8/).

**Classification: `researcher_reconstructed_fv8_npm_harness`.** FV8 has no npm or Node.js
mode. This experiment compiles the authors' released V8 patch, unmodified, into Node.js and runs
npm on that runtime. The Node.js host, a small build-compatibility header and the npm harness were
built for this study; they are not FV8.

## 1. What FV8 is

FV8 ("A Forced Execution JavaScript Engine for Detecting Evasive Techniques", Pantelaios and
Kapravelos, arXiv:2405.13175) is a modified V8 JavaScript engine. It combines two changes:

- **Forced execution.** When V8 compiles code that the program would normally skip (the untaken
  side of an `if`, a `switch` case, a loop body, a `catch` block, the other side of `a ? b : c`),
  FV8 checks whether the skipped code mentions an API it is looking for. If it does, FV8 compiles
  that code so that it runs anyway. Code that only runs under certain conditions, such as
  evasive code, then runs whatever the conditions are.
- **VisibleV8 logging.** FV8 includes the VisibleV8 patches, which write a log of every native API
  call and of every script's source to `vv8-*.log` files.

## 2. How the official implementation works

Inspected at `wspr-ncsu/FV8@57fc2b2699563316958603934aba572907171162` (2024-07-09, pinned as the
submodule `tools/fv8`).

| Item | What it is |
| --- | --- |
| `deb_files/chromium-browser-stable_122.0.6261.111-1_amd64.deb` | The authors' FV8 build: a Chromium 122.0.6261.111 browser (amd64). Its binary embeds V8 **12.2.281.21** and contains FV8's `Found match for API:` string and VisibleV8's `vv8-%ld-%d-%d-%s` log-name pattern (checked by `inspect-fv8-release.sh`). |
| `celery_workers/chromium_122_fv8_Apr24.deb` | Byte-identical to the file above (same SHA-256); the crawler's worker image installs it. |
| `patches/V8_patch_122.diff` | FV8's V8 source changes: a `diff -ru srcA srcB` of V8's `src/` directory, 28 files, 2659 lines. It does not record which V8 revision it is based on. |
| `celery_workers/`, `backend/`, `scripts/`, `crawler_queue*.py`, `docker-compose*.yaml` | A web crawler: Puppeteer drives the FV8 Chromium to visit Tranco websites; Celery/Postgres/Mongo collect and parse the VisibleV8 logs. |

The README documents three uses: run the Chromium `.deb` directly
(`chromium-browser-stable --headless --no-sandbox ... --js-flags='--no-lazy' <url>`), apply
`patches/` to V8 and build it yourself, or run the crawler.

What the patch changes (read from the diff):

- `interpreter/bytecode-generator.cc`: `AstTraversal()`, called for the untaken parts of `if`,
  `switch`, `while`, `do`/`while`, `for`, `for-in`, `for-of`, `try`/`catch` and `?:`. It walks
  the skipped code (up to a stack of 200 nodes, following calls to functions declared elsewhere)
  looking for a variable named `eval`, `Function`, `setTimeout`, `setInterval`, `append`,
  `prepend`, `insertAfter`, `insertBefore`, `window.fetch` or `fetch`. On a match it prints
  `Found match for API: <api> ...` to standard output and generates bytecode for the skipped code
  so that it runs.
- `parsing/parser.cc`, `ast/ast.h`: record every declared function, so the traversal can follow
  calls into them.
- `runtime/runtime-test.cc`, `builtins/*`, `objects/*`, `runtime/runtime.h`, `init/v8.cc`:
  VisibleV8 logging. Each thread that calls a native API writes
  `vv8-<ms>-<pid>-<tid>-<thread>.<n>.log` **in the process's current working directory** (on
  Linux), recording API calls with their arguments (`c`/`n` lines), scripts (`$<id>:<name>:<source>`),
  isolates (`~`) and origins (`@`). Property get/set tracing is behind `#ifdef
  VV8_TRACE_PROPERTIES`, which the patch does not define.
- Nine `wasm/` and `compiler/wasm-*` files: no FV8 logic. These hunks remove V8's `kExternString`
  wasm heap type; see section 9.

**There is no runtime switch for forced execution.** It is compiled in and always active.
`--no-lazy` (from the README example) is an ordinary V8 flag that makes V8 compile every function
when its script loads, instead of on first call, so FV8 examines every function and records every
declared function.

## 3. Does the published implementation support npm packages?

**No.** Of the options A–D:

| Option | In the FV8 repository? |
| --- | --- |
| A. Instrumented Node.js runtime | No |
| B. Instrumented standalone V8 runtime (`d8`) | No binary. The patch could be built into `d8`, but `d8` has no `node:fs`, `node:os`, `process`, `child_process`, or npm, so neither npm nor the probe could run. |
| C. Instrumented Chromium runtime | **Yes, this is the only executable FV8 artifact.** |
| D. Other mechanism | Only the website crawler around C. |

The Chromium build cannot run npm or an npm lifecycle script: a browser has no Node.js runtime,
no npm, and no `node:*` modules, and `npm install` does not start a browser. The `.deb` is
therefore only inspected (to read its Chromium/V8 versions), never run.

## 4. What was adapted or reconstructed

Following the requested priority:

1. *Authors' original npm workflow*: none exists.
2. *Authors' instrumented runtime used in an npm-compatible way*: impossible (option C above).
3. *Minimal reconstruction from the authors' released patch*: **used.**

The patch needs a V8 that matches it, and npm needs Node.js. Node.js's `main` branch carried
**V8 12.2.281.27** from 2024-03-31 (`09a8440b`, "deps: update V8 to 12.2.281.27") until
2024-04-19 (`1d29d81c`, "deps: update V8 to 12.3.219.16"). No Node.js release shipped V8 12.2
(Node.js 21 used 11.8, Node.js 22.0.0 used 12.4). This experiment uses the last commit before the
12.3 update:

> `nodejs/node@07f481cfcf1153336534dc5d3cd4c5c9770a72be` (2024-04-19), bundled V8 12.2.281.27,
> reports itself as `v22.0.0-pre`, bundles npm 10.5.2.

This is the same V8 12.2.281 branch as the authors' Chromium build (12.2.281.21), six patch
releases later.

| Component | Source | Changed? |
| --- | --- | --- |
| `V8_patch_122.diff` | FV8 authors | **Unmodified.** Applied with `patch -p2 -F0 --forward` in `deps/v8/src`. All hunks in all 28 files apply with exactly matching context (no fuzz); two hunks are found a few lines from where the diff expects them (GNU patch 2.7.6: `ast/ast.h` +8 lines, `parsing/parser.cc` −1 line), which changes nothing in what is applied. Checked against the pinned commit before writing the workflow; the build fails on any failed hunk or fuzz and records the offsets in `runtime/patch-apply.log`. |
| Node.js `main@07f481cf` | Node.js project | Unmodified apart from the patch above and the header below. |
| `experiments/fv8/compat/build/build_config.h` | **This study** | New file, copied to `deps/v8/build/build_config.h`. The patch includes Chromium's `build/build_config.h` and uses `BUILDFLAG(IS_ANDROID)` twice (to choose the VisibleV8 log path). Node.js does not ship Chromium's `build/` directory. The file defines only those macros, with Chromium's meaning (`IS_ANDROID` = 0 on Linux). No FV8 logic. |
| `--v8-options=--no-lazy` (default) | **This study**, following the authors' README | Baked into the binary with Node.js's `./configure --v8-options`, because the npm lifecycle starts `node` by name and Node.js rejects `--no-lazy` in `NODE_OPTIONS`. Chromium's equivalent is `--js-flags`. Selectable (`none`). |
| npm harness, canary package, verification | **This study** | See sections 5 and 7. |

The FV8 V8 patch is **not** ported to another V8 release, and nothing upstream (VisibleV8, newer
V8) is substituted. The build fails if the patch file's SHA-256, the FV8 commit, the Node.js
commit or the bundled V8 version differ from the pins.

Build: Ubuntu 24.04's GCC 13 and Python 3.12 (`./configure && make -j$(nproc) && make install`),
on the runner itself. The result is cached with `actions/cache`, keyed on the variant, the build
options and the hashes of the build script, the compatibility header and the FV8 patch. A cached
runtime is re-checked on every run (binary hash, versions, FV8 code present, canary).

## 5. Execution layers

```text
GitHub infrastructure
→ GitHub Actions ubuntu-24.04 hosted VM (x64, no container)
→ FV8 runtime: Node.js main@07f481cf + FV8 V8 patch (V8 12.2.281.27, forced execution, VisibleV8 logs)
→ npm install <npm-probing-package-0.1.0.tgz> --foreground-scripts   (npm 10.5.2 on the FV8 runtime)
→ sh -c "node scripts/postinstall.js"   (`node` = the FV8 runtime)
→ npm-probing-package postinstall → results/install-<uuid>.json
```

The lifecycle `node` resolves to the FV8 runtime because the runtime's `bin/` is placed first on
`PATH` for the npm process. That is the only change to the environment. The work directory is a
fresh empty directory (`$RUNNER_TEMP/install-probe`), as in the Packj experiment.

## 6. Does npm itself run inside FV8?

Selectable with the `npm_host` input:

- **`fv8-node` (default): yes.** npm is the npm bundled with the pinned Node.js commit and runs on
  the FV8 runtime, so npm's own JavaScript is also force-executed and logged. This matches how FV8
  is used in the browser, where all JavaScript runs on the instrumented engine.
- **`system-node`: no.** npm runs on the runner's `actions/setup-node` Node.js 22 (as in the
  baseline); only the lifecycle script (`node scripts/postinstall.js` and anything it starts with
  `node`) runs on the FV8 runtime. Use this if npm misbehaves under forced execution.

In both modes, Node.js's own internal JavaScript in the lifecycle process is compiled by FV8 too.

## 7. How forced execution is enabled and verified

Forced execution is always on in the patched build (no flag); `--no-lazy` makes it see every
function. The harness checks that it is active without changing the probe:

1. **Binary.** The installed `node` contains FV8's `Found match for API:` string and VisibleV8's
   log-name pattern; the control binary contains neither.
2. **Canary, run directly.** `experiments/fv8/smoke-package/canary.cjs` has three blocks that
   ordinary JavaScript never runs (`if (false)`, an `if` that is false at run time, `while (false)`),
   each calling `setTimeout`. On the FV8 runtime all three must run (`forced:*` markers),
   FV8 must print `Found match for API: setTimeout`, and a VisibleV8 log must record `canary.cjs`.
   On the control none of this may happen.
3. **Canary through npm.** The same canary as the `postinstall` of a throwaway package
   (`lifecycle-smoke-package`), installed with the same npm command. It must report that it ran as
   `postinstall` on `<runtime>/bin/node`, with the forced markers, and its process (by PID) must
   have written a VisibleV8 log. Its directory and npm cache are deleted before the probe runs.
4. **The probe.** Checked from what the probe and FV8 produced (`verify-fv8-run.sh probe`):
   - npm installed the package and printed the `postinstall` banner;
   - exactly one `install-*.json` was recovered; phase and `npm lifecycle event name` are
     `postinstall`; package manager is the npm that ran;
   - the probe's own `Node.js version` / `V8 engine version` equal the experiment runtime's
     (`22.0.0-pre` / `12.2.281.27-node.*`). The runner's setup-node Node.js 22 reports a different
     version and V8 12.4, so a lifecycle run under ordinary Node.js fails this check;
   - **FV8 only:** a VisibleV8 log written in the probe's package directory contains a script
     record for `…/npm-probing-package/scripts/postinstall.js`, i.e. the probe ran on the
     instrumented engine. **Control only:** no VisibleV8 log anywhere.

`harness-classification.json` turns these into one label:

| Label | Meaning |
| --- | --- |
| `runtime_unavailable` | Runtime not built/restored, or does not start |
| `install_failed` | npm did not install the package |
| `installed_lifecycle_not_executed` | Installed; npm never started `postinstall` |
| `lifecycle_ran_no_probe_output` | `postinstall` started; no report |
| `probe_executed_under_ordinary_node` | Report exists, but from a different Node.js/V8 |
| `probe_executed_on_fv8_runtime_build_instrumentation_unverified` | Right runtime, no VisibleV8 record of the probe |
| `probe_executed_under_fv8_instrumentation_forced_execution_unverified` | Probe recorded by VisibleV8; canaries did not show forced execution |
| `probe_executed_under_fv8_instrumentation_forced_execution_active` | **Fully verified FV8 run** |
| `probe_executed_under_control_runtime_verified` / `_unverified` | Control outcomes |

Whether forced execution changed anything *inside the probe* depends on whether the probe has
untaken branches that mention FV8's targeted APIs. The `Found match` lines printed between npm's
`postinstall` banner and npm's next output are counted
(`forced_execution_evidence.found_match_lines_in_postinstall_window`). Attributing them to the
probe process this way is positional, not exact.

## 8. Versions

| | Value | Source |
| --- | --- | --- |
| FV8 commit | `57fc2b2699563316958603934aba572907171162` | `tools/fv8` submodule, verified by the workflow |
| FV8 patch | `patches/V8_patch_122.diff`, SHA-256 `6dc76720…0a3c39` | verified by the workflow |
| Authors' Chromium | 122.0.6261.111 | `.deb` control file, read by the workflow |
| Authors' V8 (base) | 12.2.281.21 | version string in the authors' `chrome` binary, read by the workflow |
| Runtime Node.js | `nodejs/node@07f481cf`, `v22.0.0-pre` | pinned in `build-node-runtime.sh` |
| Runtime V8 | 12.2.281.27 (+ Node.js's floating patches) | `deps/v8/include/v8-version.h`, checked at build |
| npm (default host) | 10.5.2, bundled with that Node.js commit | `lib/node_modules/npm/package.json` |

All of these are written to `fv8-metadata.json` and `experiment-manifest.json` from the run.

## 9. Limitations of calling this an "FV8 npm scanner"

- **It is not the authors' runtime.** The authors ship FV8 as Chromium. This is their V8 patch
  inside Node.js, built for this study. Results describe "FV8's instrumentation hosted in Node.js",
  not a tool the authors released or evaluated.
- **V8 12.2.281.27, not .21.** The patch's `srcA` tree was a later 12.2.281 build than the one
  FV8 was built on: applied to Node.js's .27, the nine wasm files come out byte-identical to
  12.2.281.21 (they undo the `kExternString` wasm change). The other 49 files in which the
  patched `deps/v8/src` differs from 12.2.281.21 (outside the 28 patched files) are V8 patch
  releases and Node.js's own V8 patches, not FV8.
- **Unreleased Node.js.** `v22.0.0-pre` is a development build of `main`. The probe declares
  `engines: node >=22`; a prerelease does not satisfy that, so npm may print an `EBADENGINE`
  warning (it does not stop the install). With the default `fv8-node` host, npm is 10.5.2, not the
  baseline's setup-node npm.
- **Browser-oriented targets.** FV8 forces only code that mentions `eval`, `Function`,
  `setTimeout`, `setInterval`, `fetch`, `append`, `prepend`, `insertAfter` or `insertBefore`.
  Node.js-specific behaviour (`child_process`, `fs`, `process.env` checks) is not a trigger
  unless such a name is also present.
- **Everything is instrumented.** Node.js's internal JavaScript, and npm in the `fv8-node` mode,
  are force-executed and logged as well. VisibleV8's origin record (`@`) assumes a browser
  `window`; in Node.js it logs `@?`.
- **FV8 leaves traces the probe can see.** VisibleV8 creates `vv8-*.log` files in each process's
  working directory, including the probe's own package directory, and FV8 prints `Found match for
  API` lines to standard output. These are FV8 behaviour (the same code does this in Chromium) and
  are recorded, not removed. The control shows neither.
- **Toolchain.** Built with GCC 13/libstdc++, not Chromium's clang/libc++. GCC ignores the patch's
  `[[clang::no_destroy]]` (warning only), so FV8's two global vectors are destroyed at process exit.
- **Unknown authors' build options.** Whether the authors' Chromium was built with
  `VV8_TRACE_PROPERTIES` (property get/set logging) is not documented; it is left undefined here,
  as the patch leaves it.
- **Not part of the authors' pipeline.** The crawler, Celery workers and log parsers are not used;
  VisibleV8 logs are kept raw.
- **Snapshot.** Node.js's build runs the new engine (`node_mksnapshot`) over Node's bootstrap
  code. If forced execution breaks that step, rerun both workflows with
  `node_snapshot: no-snapshot`; that changes Node.js startup for both and is recorded.

## 9a. FV8's released patch crashes Node.js's build; optional one-line fix

**Observed (2026-10-14, run 38494602753, container experiment, `variant: fv8`).** With the FV8
patch applied verbatim, all of V8 and Node.js compiled and linked with GCC 13, and V8's
`mksnapshot` ran. Node.js's `node_mksnapshot`, which runs the new engine over Node's bootstrap
JavaScript, then crashed: `Segmentation fault (core dumped)`, make error 139, before any
`Found match for API` line. The hosted-VM workflow builds identical code and would fail the same
way. **No FV8 runtime has been produced with the patch as released.**

**Likely cause: a bug in the released patch, not in the port.** `AstTraversal()` dispatches on
numeric `AstNode::NodeType` values. Computed from V8 12.2's `AST_NODE_LIST` (identical in the
authors' 12.2.281.21 and Node's 12.2.281.27), ten of FV8's eleven case labels match the node
type they cast to. `case 44` does not: FV8 handles it as `Property` (`pair.first->AsProperty()`),
but 44 is `OptionalChain` and `Property` is 45. `AsProperty()` returns `nullptr` for a non-Property
node, and FV8 then calls `node44->key()`. Any untaken branch that FV8 traverses and that contains
an optional chain (`a?.b`) dereferences a null pointer. Node.js's internal JavaScript uses
optional chaining. The authors' comment on that line reads `// case 45:`. This is the likely
cause; it has not been confirmed with a stack trace.

**Fix (opt-in, researcher change, not FV8):**
[`experiments/fv8/patches/fv8-astnode-property-case.patch`](../experiments/fv8/patches/fv8-astnode-property-case.patch)
changes `case 44:` to `case 45:` and nothing else (`OptionalChain` then takes the switch's
`default:` branch, like every other node type FV8 does not handle). It is applied after the
verbatim FV8 patch, with `patch -F0` and a SHA-256 check, only when the workflow input
`fv8_fixes: property-case` is chosen (FV8 variant only). The default remains `none`, FV8 exactly
as released.

Recorded in every run: `runtime/build-info.json` (`fv8_patch_as_released`, `researcher_fv8_fixes`,
`researcher-fix-apply.log`, the fix in `source-changes.diff`), `fv8-metadata.json` (provenance),
`experiment-manifest.json` (`fv8_patch_as_released`, `fv8_researcher_fixes`). Results obtained with
the fix describe "FV8 with one corrected case label", not FV8 as released.


**Result with `property-case` (2026-10-14, runs 38505885979 and 38532680501): still crashes.** The
`case 44` bug is real but was not this crash. Run 38532680501 replayed the failing step under gdb
(`crash_diagnostics: true`):

```text
SIGSEGV in v8::internal::interpreter::BytecodeGenerator::AstTraversal(AstNode*)
  <- BytecodeGenerator::VisitIfStatement <- VisitStatements <- GenerateBytecodeBody
  <- ... Compiler::GetWrappedFunction <- ScriptCompiler::CompileFunctionInternal
faulting instruction: mov 0x4(%rax),%eax ; and $0x3f,%eax   (reads AstNode::NodeType)
rax = 0xd6000020e18df006                                    (not a valid pointer)
```

VisibleV8's log shows it happened while compiling `node:internal/options`, after about 14 Node.js
modules had been compiled. **Cause (from FV8's code and the trace):** FV8 appends every declared
function (`FunctionLiteral*`) and its name (`AstRawString*`) to two process-global vectors and
never clears them. Both point into the parse's Zone, which V8 frees after each compilation.
`AstTraversal` compares names by pointer and, on a match, reads `declared_functions[i]->node_type()`.
Once freed memory is reused, a stale entry matches and FV8 reads through a dangling pointer. This
is a memory-safety bug in the released FV8 code; whether it crashes depends on how memory is reused.

**Second fix (opt-in, researcher change, not FV8):**
[`experiments/fv8/patches/fv8-parser-reset-declared-functions.patch`](../experiments/fv8/patches/fv8-parser-reset-declared-functions.patch)
clears both vectors at the end of V8's `Parser` constructor (four added lines), so they only ever
hold nodes of the AST about to be compiled. Selected with `fv8_fixes: property-case+parser-reset`
(both fixes, in order). **Behaviour change:** FV8 no longer follows a function name into functions
declared in earlier parses or other scripts (which, as released, reads freed memory). Within one
compilation (with `--no-lazy`, a whole script) it still does. Assumes parsing and compilation on
one thread, as in `node_mksnapshot` and Node.js's module loading; FV8's vectors are not
thread-safe either way.

**Upstream issue noted, not changed:** `AstTraversal` sorts and de-duplicates
`declared_functions_names` but not `declared_functions`, then indexes both with the same `i`, so a
matched name can be paired with a different function. That is wrong, but not unsafe.

`fv8_fixes` values: `none` (FV8 as released: crashes), `property-case` (crashes, as above),
`property-case+parser-reset` (both fixes). The workflow records which one was used.

## 10. How probe output is recovered

The probe is unchanged and writes its report with its default mechanism:
`<work>/node_modules/npm-probing-package/results/install-<uuid>.json`. No probe-specific
environment variable (e.g. `NPM_PROBE_OUTPUT_DIR`) is set. `run-npm-install.sh` copies it to
`results/<experiment>/<run-id>/probe/` and records whether any report went to the probe's
temporary-directory fallback instead. If no report exists, nothing is created in its place: the
probe check fails and the label says why.

Experiment metadata is written to separate files and only after the probe has finished, except
`environment-metadata.json`, which is written before the runtime is built and is never placed
where the probe can read it.

## 11. Artifact layout

Artifact `fv8-probe-<run_id>-<run_attempt>` (control: `fv8-control-probe-<run_id>-<run_attempt>`),
containing `results/fv8/<run_id>/` (control: `results/fv8-control/<run_id>/`):

```text
probe/install-<uuid>.json            the probe's report
environment-metadata.json            runner/OS/kernel/CPU/memory/Docker/Node/npm, before FV8
fv8-metadata.json                    FV8 commit, patch, released build, runtime build, provenance
harness-classification.json          verification results and label
experiment-manifest.json             summary record
README.md                            what is in the directory
checks/{runtime,smoke,probe}.json    individual checks
fv8/released-build.json              authors' Chromium .deb: versions, hashes, markers
runtime/                             build-info, patch-apply log, source diff, self-test, canary
install/smoke/                       canary package install (not the probe)
install/probe/npm-install.log        execution log
install/probe/vv8-logs/              VisibleV8 logs: lifecycle/ (probe process), npm/*.gz (npm)
install/probe/forced-execution-markers.txt, postinstall-window.log, run-paths.json, npm-logs/
logs/setup-build.log                 runtime build log (from the building run if cached)
logs/github-host.txt, logs/runtime-source.txt, logs/credential-scan.txt
```

**Secrets.** No secrets are passed to the job; permissions are `contents: read`. VisibleV8 records
API call arguments, so before upload every result file is searched for credential-shaped strings
(GitHub, AWS, npm, Slack tokens, private keys). Matching files are removed from the upload and
listed in `logs/credential-scan.txt`; matches are never printed.

## 12. Reproducing

On GitHub (the workflow files must be on the default branch):

```bash
gh workflow run fv8-probe.yml --ref main            # defaults: npm_host=fv8-node, v8_options=--no-lazy
gh workflow run fv8-control-probe.yml --ref main    # same inputs as the FV8 run
gh run list --workflow fv8-probe.yml --limit 1
gh run download <run-id> -n fv8-probe-<run-id>-1
gh run download <control-run-id> -n fv8-control-probe-<control-run-id>-1
```

The first run of each variant builds Node.js (about 1.5–2 hours on a 4-vCPU runner); later runs
restore it from the cache. `rebuild_runtime: true` forces a fresh build.

Locally on Ubuntu 24.04 x64 (needs `git`, `gcc`/`g++` ≥ 10.1, `make`, `python3`, `jq`):

```bash
git submodule update --init --depth 1 tools/fv8
bash experiments/fv8/build-node-runtime.sh fv8 /tmp/node-build /tmp/node-runtime --no-lazy snapshot
mkdir -p out/probe
bash experiments/fv8/run-runtime-selftest.sh /tmp/node-runtime out /tmp/selftest
bash experiments/fv8/verify-fv8-run.sh runtime out fv8 --no-lazy
bash experiments/fv8/run-npm-install.sh /tmp/node-runtime fv8-node \
  packages/npm-probing-package-0.1.0.tgz /tmp/install-probe out/install/probe \
  npm-probing-package out/probe
bash experiments/fv8/verify-fv8-run.sh probe out fv8
```

Equivalent manual command for the install step:

```bash
cd "$(mktemp -d)"
PATH=/tmp/node-runtime/bin:$PATH npm install /path/to/npm-probing-package-0.1.0.tgz --foreground-scripts
```
