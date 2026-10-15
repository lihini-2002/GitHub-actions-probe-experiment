# EC2 baseline collection procedure

Completed results are in [results/ec2/baseline](../../results/ec2/baseline/README.md). The final matched cohort contains ten new successful installations (run-002 through run-011). The original run-001 is preserved but excluded because automatic apt upgrades occurred after it. There are eleven retained successful observations overall. The remote repository stayed at `9660c7d01e31499de60f116fb6ce56ee76e9b69d`, even though the local repository subsequently advanced.

The probe archive is `packages/npm-probing-package-0.1.0.tgz` (version 0.1.0), SHA-256 `8ba84a1e7145dd5024380a9177cd24939591c0822b06afb37568f661ea084ba4`. No repacking or probe changes occurred. Installation was `npm ci` from `/home/ubuntu/research/GitHub-actions-probe-experiment`, using the existing package-lock and default npm lifecycle behavior. The package writes `node_modules/npm-probing-package/results/install-<UUID>.json` during `postinstall`.

The original results remain untouched at `/home/ubuntu/research/ec2-baseline-20261014`. They were copied into the organized `run-001` directory; its original raw JSON and metadata were retained. New per-run metadata is named `experiment-metadata.json` to avoid replacing the original metadata. The earlier local results directory was absent when this task started; the original was recovered from EC2.

## Scripts

- `prepare-runs.py`: run as ubuntu on EC2; verifies the fixed commit/archive and copies the original run, refusing overwrite.
- `repeat-in-session.sh`: paste/source into an interactive Session Manager bash after `sudo -iu ubuntu`. This preserves the original session/shell ancestry and records nine `npm ci`, `npm test`, `npm run build` sequences; the same loop with the single number `011` collected the tenth new installation with `tee`. Do not run it again against existing directories. `npm ci` naturally removes/recreates node_modules; previous reports are copied out before the next installation.
- `finalize-runs.py`: run as ubuntu on EC2; validates all eleven retained reports and selects the ten new observations, unique run IDs, schema/catalog labels and exit codes; records metadata and exact value/status stability. It does not invoke the probe.
- `ssm-command.py`: executes an explicitly supplied shell file against this research host and saves the SSM command result. Used for preparation/validation, not the baseline npm installs.
- `download-results.py`: retrieves the collected files in bounded chunks; verifies archive and individual file SHA-256 hashes and refuses to overwrite different local files.

No package/environment variables were injected for the experiment, no npm cache was cleaned, and no OS reinstall or scanner instrumentation was used. Variables controlling run numbers/output paths were shell-local, not exported. npm output was piped to tee, just as in the original successful run; the package uses npm's normal background lifecycle execution. A terminal on the parent Session Manager shell does not mean the lifecycle child has a terminal.

Run 001 was the fresh installation in an earlier session. Package logs showed ten automatic apt upgrades afterward at 06:08–06:09 UTC, so it was excluded. Runs 002–010 were warm-cache repeats in a later session. Run 011 followed the provisional AMI consistency reboot and completed the ten-new-run cohort. The full apt inventories before/after that tenth new run match. Home/history/logs were not reset. The final AMI was requested after run 011; the provisional AMI is superseded. The fixture test/build scripts only print success messages; probe validation independently verifies the generated reports.

If an installation fails, its exit codes/logs are retained and it is not considered successful. No npm installation failed in this collection. Two preparatory/readback commands needed corrections (metadata file path and an automatic connection-review timeout); neither was a probe run.

Raw features are unchanged. Account/instance/image IDs, dates, run IDs, commits, hashes, context files, and metadata are experiment bookkeeping and should not enter classifier features.
