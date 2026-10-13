'use strict';
// Forced-execution canary for the FV8 experiment harness (not the probe).
//
// Each guarded block below can never run in ordinary JavaScript. FV8's
// bytecode generator force-compiles a branch that the program would skip when
// that branch references one of its targeted APIs (setTimeout, eval,
// Function, setInterval, fetch, ...). Each block therefore references
// setTimeout. If a "forced:*" marker is written, the engine executed a branch
// that ordinary V8 never executes.
//
// The canary does nothing else: the timers are cleared immediately and the
// only output is <out-file>.
//
// Usage: node canary.cjs <out-file>

const fs = require('node:fs');
const path = require('node:path');

const out = path.resolve(process.argv[2] || 'markers.json');
const markers = [];
const mark = (name) => { markers.push(name); };

mark('start');

// Constant-false condition: FV8 handles this in VisitIfStatement's
// ToBooleanIsFalse case.
if (false) {
  clearTimeout(setTimeout(() => {}, 0));
  mark('forced:constant-false-if');
}

// Condition only known at run time (false here): FV8's general case, where
// the branch is force-compiled after the normal conditional.
if (process.argv.length > 1000) {
  clearTimeout(setTimeout(() => {}, 0));
  mark('forced:runtime-false-if');
}

// Loop body that never runs: FV8 traverses loop bodies before compiling them.
while (false) {
  clearTimeout(setTimeout(() => {}, 0));
  mark('forced:never-entered-while');
}

mark('end');

fs.writeFileSync(out, JSON.stringify({
  markers,
  pid: process.pid,
  exec_path: process.execPath,
  node_version: process.version,
  v8_version: process.versions.v8,
  exec_argv: process.execArgv,
  cwd: process.cwd(),
  npm_lifecycle_event: process.env.npm_lifecycle_event ?? null,
}, null, 2) + '\n');
