// Run the upstream LATCH analyzer over one package's straces and report what
// it produced.
//
// Runs inside the LATCH image, installed at /latch/experiment/. The upstream
// analyzer resolves its inputs relative to its own directory:
//   /latch/straces/<pkg>/<pkg>_<script>.<pid>   strace files from the npm hook
//   /latch/manifests/<pkg>_<script>             manifests (JSON, no extension)
//   /latch/analyzer/errors.txt                  "<pkg> <script> analyzer_failed"
// so this wrapper only calls Analyzer.Analyze(pkg) and inspects those paths.
// Manifest serialization itself is the one-line change in
// patches/latch-analyzer-reproduction.patch.
//
// Must stay parseable by Node 12 (no optional chaining / nullish coalescing).
//
// Usage: node generate-manifest.js <name@version> <lifecycle-cwd> <summary.json>

const fs = require("fs");
const path = require("path");

const [, , pkg, lifecycleCwd, summaryPath] = process.argv;
if (!pkg || !lifecycleCwd || !summaryPath) {
  console.error(
    "Usage: node generate-manifest.js <name@version> <lifecycle-cwd> <summary.json>"
  );
  process.exit(2);
}

const latchRoot = path.join(__dirname, "..");
const stracePath = path.join(latchRoot, "straces");
const manifestPath = path.join(latchRoot, "manifests");
const scriptErrorPath = path.join(latchRoot, "analyzer", "errors.txt");

// The scripts Analyzer.Analyze iterates over, in its order.
const SCRIPTS = [
  "preinstall",
  "install",
  "postinstall",
  "preuninstall",
  "uninstall",
  "postuninstall",
];

// Keys returned by Analyzer.CreateManifest.
const MANIFEST_KEYS = [
  "successful", "timedOut", "metadataRequests", "metadataMods", "openRead",
  "openWrite", "read", "write", "rename", "delete", "create", "runtime",
  "privateHosts", "localHosts", "publicHosts", "elevatedExecs", "lowerExecs",
  "ruidroot", "euidroot", "rgidroot", "egidroot", "sendToKernel",
  "recvFromKernel", "sendToProcess", "recvFromProcess",
];

const name = pkg.replace(/\//g, "~");

function straceFiles(script) {
  const dir = path.join(stracePath, name);
  if (!fs.existsSync(dir)) return [];
  const prefix = name + "_" + script + ".";
  return fs
    .readdirSync(dir)
    .filter((f) => f.startsWith(prefix) && /^\d+$/.test(f.slice(prefix.length)))
    .map((f) => path.join(dir, f));
}

function readErrors() {
  return fs.existsSync(scriptErrorPath)
    ? fs.readFileSync(scriptErrorPath, "utf8")
    : "";
}

// Upstream OSstate seeds the first traced process with a path from the
// authors' machine; give it the directory npm actually ran the script in.
process.env.LATCH_INITIAL_CWD = lifecycleCwd;

const errorsBefore = readErrors();
const analyzer = require(path.join(latchRoot, "analyzer", "analyzer"))();
const started = Date.now();
analyzer.Analyze(pkg);
const elapsedMs = Date.now() - started;
const newErrors = readErrors().slice(errorsBefore.length);

const stages = {};
let traced = 0;
let failures = 0;

SCRIPTS.forEach((script) => {
  const files = straceFiles(script);
  const bytes = files.reduce((n, f) => n + fs.statSync(f).size, 0);
  const manifestFile = path.join(manifestPath, name + "_" + script);
  const failed = newErrors
    .split("\n")
    .indexOf(pkg + " " + script + " analyzer_failed") !== -1;
  const stage = {
    straceFiles: files.length,
    straceBytes: bytes,
    finishedMarker: fs.existsSync(
      path.join(stracePath, name, name + "_" + script + "_finished")
    ),
    killedMarker: fs.existsSync(
      path.join(stracePath, name, name + "_" + script + "_killed")
    ),
    analyzerFailed: failed,
    manifestWritten: fs.existsSync(manifestFile),
  };

  if (stage.manifestWritten) {
    try {
      const manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
      stage.manifestValidJson = true;
      stage.manifestMissingKeys = MANIFEST_KEYS.filter((k) => !(k in manifest));
      stage.manifestCounts = {};
      MANIFEST_KEYS.forEach((k) => {
        if (Array.isArray(manifest[k])) stage.manifestCounts[k] = manifest[k].length;
      });
      stage.manifestSuccessful = manifest.successful;
      stage.manifestTimedOut = manifest.timedOut;
      stage.manifestRuntimeSeconds = manifest.runtime;
    } catch (err) {
      stage.manifestValidJson = false;
      stage.manifestError = err.message;
    }
  }

  if (files.length > 0) {
    traced += 1;
    const usable =
      stage.manifestWritten &&
      stage.manifestValidJson &&
      stage.manifestMissingKeys.length === 0 &&
      !failed;
    stage.ok = usable;
    if (!usable) failures += 1;
  }
  stages[script] = stage;
});

const summary = {
  package: pkg,
  lifecycleCwd: lifecycleCwd,
  analyzerNodeVersion: process.version,
  analyzerElapsedMs: elapsedMs,
  tracedStages: SCRIPTS.filter((s) => stages[s].straceFiles > 0),
  analyzerErrors: newErrors.split("\n").filter(Boolean),
  stages: stages,
  ok: traced > 0 && failures === 0,
};

fs.writeFileSync(summaryPath, JSON.stringify(summary, null, 2) + "\n");
console.log(JSON.stringify(summary, null, 2));

if (traced === 0) {
  console.error("No strace files found for " + pkg + " under " + stracePath);
  process.exit(1);
}
if (failures > 0) {
  console.error(failures + " traced stage(s) did not produce a usable manifest");
  process.exit(1);
}
