//npm installs and uninstalls a package version
//
// Adapted from tools/latch/singularity/containerScriptSingle.js for the
// GitHub Actions experiment. Installed in the image as /start.js, as upstream.
// Differences from upstream, all outside the traced lifecycle scripts:
//   1. The package is a local tarball, so the install spec (a path), the
//      uninstall spec (the package name) and the strace key (name@version,
//      the pkg._id the npm hook names traces by) are passed separately.
//      Upstream used one "name@version" string for all three.
//   2. Between install and uninstall, the probe's report is copied out of
//      node_modules/<name>/results/, because uninstall deletes it. The copy
//      happens after npm install has returned, so after postinstall finished.
//   3. Exit status is non-zero when install failed, so the workflow can see it.
//      Upstream only recorded failures in <key>_FAILED.

const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const pkgSpec = process.argv[2];
const pkgName = process.argv[3];
const pkgKey = process.argv[4];
const collectDir = process.argv[5];
const npmCommand = "node /cli/bin/npm-cli.js";
const stracePath = __dirname + "/../straces";

function recordFailure(error) {
  const name = pkgKey.replace(/\//g, "~");
  if (!fs.existsSync(path.join(stracePath, name))) {
    fs.mkdirSync(path.join(stracePath, name));
  }
  fs.appendFileSync(
    path.join(stracePath, name, name + "_FAILED"),
    error.name + "\n" + error.message + "\n"
  );
}

function collectProbeReports() {
  const sources = [
    path.join(process.cwd(), "node_modules", pkgName, "results"),
    // The probe's last-resort output directory (os.tmpdir()).
    path.join("/tmp", pkgName + "-results"),
  ];
  let copied = 0;
  sources.forEach((dir) => {
    if (!fs.existsSync(dir)) return;
    fs.readdirSync(dir)
      .filter((f) => /^install-.*\.json$/.test(f))
      .forEach((f) => {
        fs.copyFileSync(path.join(dir, f), path.join(collectDir, f));
        console.log("Collected probe report " + path.join(dir, f));
        copied += 1;
      });
  });
  if (copied === 0) console.log("No probe report found in " + sources.join(", "));
}

let installFailed = false;
try {
  cp.execSync(npmCommand + " install " + pkgSpec, { stdio: "inherit" });
} catch (error) {
  installFailed = true;
  recordFailure(error);
}
if (collectDir) collectProbeReports();
try {
  cp.execSync(npmCommand + " uninstall " + pkgName, { stdio: "inherit" });
} catch (error) {
  recordFailure(error);
}
process.exit(installFailed ? 1 : 0);
