# Preserved clean EC2 baseline

The private AMI `ami-0b3373c3f61239eec` in `ap-southeast-2` preserves source instance `i-068e4b9f4f532e9f7` after all ten new normal npm baseline installations (run-002 through run-011; the original run-001 is retained but excluded), before any scanner installation. Image creation timestamp: **2026-10-14 09:37:33 UTC / 15:07:33 Asia/Colombo**. **Verified available**, backed by completed encrypted snapshot `snap-0aaddee2fea255e7d`. The source instance is running, EC2 health checks pass, and SSM is Online. See `preservation-metadata.json` and `final-image.json` for verification records.

Image name: `npm-research-clean-ec2-baseline-complete-20261014`. Both image and snapshot use:

- `Name=npm-research-clean-ec2-baseline`
- `Project=package-environment-fingerprint`
- `Purpose=scanner-experiment-baseline`
- `Environment=ec2-ubuntu-development`
- `ManagedBy=research-experiment`
- `SourceInstance=i-068e4b9f4f532e9f7`
- `BaselineRuns=10`

Ubuntu 24.04.5 LTS; kernel `7.0.0-1014-aws`; Node v22.23.3; npm 10.9.9; Python 3.12.3; Git 2.43.0. Installed base tools are git, curl, wget, ca-certificates, build-essential, Python 3, jq, zip, unzip, xz-utils, and the official Node distribution. `software-audit.json` lists exact base package versions, and `../../../results/ec2/baseline/base-package-manifest.tsv` records the full apt inventory.

The encrypted root EBS snapshot preserves 100 GiB gp3 configuration. This is a **post-baseline scanner-free state**, including repository/probe installation, npm cache/logs, normal home/history/SSM artifacts, eleven retained reports (ten included) and metadata. It is not a pre-first-install image. No manual software upgrade, cache cleaning, OS reinstall or scanner dependency installation was performed. Ten automatic apt updates between the original run and the repeats are documented in `intervening-package-updates.txt`; the original run is excluded. The installed apt package inventory was unchanged across the ten new observations. The image is private to this account; no launch permission was shared.

`final-create-image-request.json` records the exact API request with `NoReboot=false`. EC2's consistency reboot was allowed after measurements and session closure. The instance was retained. [AWS documents the consistency reboot and snapshot billing](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/creating-an-ami-ebs.html).

## Restore for a later scanner experiment

A concrete configuration is saved in `restore-instance-request.json`. It uses the preserved AMI, m7i.xlarge, the existing subnet, no-inbound SG `sg-06b02185a23e02db1`, SSM-only profile `npm-research-ec2-ssm-profile`, encrypted 100 GiB gp3, and required IMDSv2 with hop limit 1. It does not supply the original provisioning user-data script, which could reinstall tools.

When ready to create a separately billed experimental host, review its Name tag and then run from the repository root:

```sh
aws sts get-caller-identity
# Confirm account 164237866526.
aws ec2 run-instances --region ap-southeast-2 \
  --cli-input-json file://infra/aws/clean-baseline/restore-instance-request.json
```

Record the returned instance ID, wait for EC2 health and SSM Online, then connect:

```sh
aws ssm start-session --region ap-southeast-2 --target NEW_INSTANCE_ID
# In the session:
sudo -iu ubuntu
cd ~/research/GitHub-actions-probe-experiment
node --version
npm --version
```

Verify Ubuntu/kernel/tool versions and compare the package inventory before scanner changes. Do not rerun `setup-ec2.sh` or bootstrap on a restored host. Original host metadata and results on the disk remain historical; create new experiment bookkeeping with the new instance ID/launch timestamp, leaving the preserved reports intact. Host identity, uptime, process state, networking and background update activity can differ after restoration even though the saved software/disk state is the starting point. If future container experiments require a metadata hop-limit change, record it explicitly and keep tokens required.

No restoration test instance was launched in this task; verification covers AMI availability, completed encrypted snapshot, private launch permissions, source host recovery and saved configuration. The next scanner task can launch from this AMI rather than modifying the only preserved source.

## Cost and retention

The final retained preservation resource is one AMI and its backing EBS snapshot. An earlier provisional image (`ami-02d706ba7627548ab`, snapshot `snap-0d86784ad837c857d`) preceded detection of the original-run package drift; it was deregistered and its snapshot deleted after the final backup was verified. `provisional-cleanup.json` records successful cleanup. Snapshot storage adds ongoing charges for stored data; retain both while they are needed for restoration. No extra running EC2 instance, Elastic IP, NAT gateway, bucket, or load balancer was created. The source host remains running and retains its normal instance/EBS/public IPv4 charges. Stop the source when idle without terminating it:

```sh
aws ec2 stop-instances --region ap-southeast-2 --instance-ids i-068e4b9f4f532e9f7
```

OpenSSF Package Analysis, Latch, Packj, FV8, Pack-A-Mal, Docker and scanner-specific gVisor remain uninstalled.
