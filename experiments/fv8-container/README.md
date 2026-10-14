# FV8 in a GitHub Actions job container

Workflow: [`fv8-container-probe.yml`](../../.github/workflows/fv8-container-probe.yml).
Design, layers, verification and comparison with the hosted-VM FV8 experiment:
[`docs/fv8-container-setup.md`](../../docs/fv8-container-setup.md).

The FV8 build, harness and checks are the hosted-VM experiment's scripts in
[`experiments/fv8/`](../fv8/), used unchanged. This directory only adds the container layer:

| File | Role |
| --- | --- |
| `record-container-layer.sh` | Snapshot of OS, kernel, PID 1, cgroup/limits, mounts, hostname, marker files → `container/<label>.{json,txt}` |
| `verify-container-layer.sh` | Checks that the build, runtime, npm and the probe ran in the job container → `checks/container.json` |
| `write-container-metadata.sh` | `container-metadata.json` (outer runner / job container / analysis layers), container fields in `experiment-manifest.json`, `README.md` |
