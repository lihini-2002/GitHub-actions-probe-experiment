# EC2 Ubuntu development-host baseline

One research host was provisioned and verified on 2026-10-14. It is running and ready for the next task: clone the existing research repository into `/home/ubuntu/research` and capture the **plain EC2 Ubuntu development-host baseline**. No experiment was run.

## Host

| Property | Value |
| --- | --- |
| Account / provisioning identity | `164237866526` / IAM user `admin-gayathri` |
| Name | `npm-research-ec2-dev` |
| Instance | `i-068e4b9f4f532e9f7` (bookkeeping only; exclude from classifier features) |
| Region / AZ | `ap-southeast-2` / `ap-southeast-2b` |
| Type / architecture | `m7i.xlarge` / `x86_64` |
| CPU / RAM | 4 vCPUs / nominal 16 GiB; guest MemTotal 16,078,380 KiB |
| Ubuntu | 24.04.5 LTS |
| Kernel | `7.0.0-1014-aws` |
| AMI | `ami-0f5e1e0151e5b95ed` |
| AMI name | `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20261004` |
| Verified Canonical owner | `099720109477` |
| EBS | 100 GiB gp3, encrypted, 3,000 IOPS, 125 MiB/s |
| Provisioned | 2026-10-14 03:06:09 UTC / 08:36:09 Asia/Colombo |

Ubuntu 24.04 matches `.github/workflows/probe.yml`; it is a supported LTS choice for comparability, not a claim that it is the newest LTS. Node major 22 also matches that workflow. A fixed-performance general-purpose x86 instance avoids burst-credit throttling or surplus charges during future builds. Future large V8 builds may require a separate sizing decision.

## Account inspection and reuse

The configured default region is Sydney and an existing `guardianagent-prod` EC2 host runs there. Existing tags use `Name`, `Project`, and `Environment`. All available/disabled region statuses are saved in `evidence/regions.json`; no regions were enabled and no compute resources were created elsewhere. The AWS Pricing API was read in us-east-1 only.

Reused the existing default VPC `vpc-00d8ff46de82538a6`, public subnet `subnet-0e470510ea99bd23e`, main route table `rtb-0f8e592443229dd0e`, and Internet gateway `igw-07319359b6adde7da`. The subnet has an active Internet-gateway route and public addressing. The other existing subnets are in AZs a and c. Existing security groups served GuardianAgent or exposed inbound ports; none was appropriate for this host, so a dedicated group was created. The existing `kasm_key` SSH key pair was not used. Existing SSM management works for GuardianAgent; account default host management is disabled. Its profile is application-specific, so a separate SSM-only role/profile was created. Unrelated resources were not changed.

## Access

Use the browser console without installing anything locally:

1. Open https://ap-southeast-2.console.aws.amazon.com/ec2/home?region=ap-southeast-2#Instances:instanceId=i-068e4b9f4f532e9f7
2. Select the instance, **Connect → Session Manager → Connect**.
3. Run `sudo -iu ubuntu`, then `cd ~/research`.

With AWS CLI credentials and the Session Manager plugin installed:

```sh
aws ssm start-session --region ap-southeast-2 --target i-068e4b9f4f532e9f7
# Inside the session:
sudo -iu ubuntu
cd ~/research
```

A real CLI Session Manager shell was opened and commands succeeded as `ubuntu`. The local plugin was absent, so verification used an official AWS binary extracted under `/tmp/npm-research-sessionmanager/`; it was not installed globally. Until that temporary directory is removed, the tested local command is:

```sh
PATH="/tmp/npm-research-sessionmanager/sessionmanager-bundle/bin:$PATH" \
  aws ssm start-session --region ap-southeast-2 --target i-068e4b9f4f532e9f7
```

Permanent optional client installation: [AWS macOS plugin instructions](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-macos-overview.html).

## Software and baseline boundary

Installed ordinary development tools: git, curl, wget, ca-certificates, build-essential (GCC/G++/make), Python 3, jq, unzip, zip, and xz-utils. Node was installed from the official Linux x64 archive with a pinned SHA-256 checksum; bundled npm was retained.

| Tool | Exact observed version |
| --- | --- |
| Node | v22.23.3 |
| npm | 10.9.9 |
| Python | 3.12.3 |
| Git | 2.43.0 |
| SSM Agent | 3.3.4793.0 |

OpenSSF Package Analysis, Latch, Packj, FV8, Pack-A-Mal, Docker, and gVisor/runsc are **not installed**. No scanner repositories/dependencies were added. The research workspace is empty. No research repository, probing package, GitHub token, Git credentials, or AWS CLI credentials were installed on the host. Normal cloud-init and SSM agent artifacts remain part of this cloud development-host baseline; Session Manager also creates its normal `ssm-user` account. Node's official archive includes Corepack 0.36.0. No snapshot or custom AMI was created.

## Security

- Dedicated SG `sg-06b02185a23e02db1` has **zero inbound rules**, including no SSH, web, or Docker ports. Default outbound IPv4 is allowed for ordinary development and SSM.
- Role `npm-research-ec2-ssm-role`, profile `npm-research-ec2-ssm-profile`; EC2 service principal only.
- The only attached policy is `arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore`; there are no inline policies. No extra S3, Secrets Manager, IAM, or administrator policy was attached. This AWS standard managed policy includes SSM parameter-read capabilities; it is not a custom session-only policy.
- IMDS endpoint enabled; tokens **required**; hop limit **1**; metadata tags disabled. A tokenless request returned HTTP 401. Future bridged-container metadata access may require hop limit 2; do not change this silently or enable IMDSv1. Host processes can still obtain the SSM role's temporary credentials through IMDSv2.
- EBS encryption verified through the EC2 API. The root disk survives stop/start and is configured for deletion on termination.
- No account-wide logging, IAM, networking, or SSM settings were changed.

See [AWS instance-profile guidance](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html) and [Canonical AMI identification](https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/).

## Reproduce and inspect

`setup-ec2.sh` calls `provision.py` using Python's standard library and AWS CLI, without adding an infrastructure framework. Terraform files under the vendored Pack-A-Mal tool are scanner infrastructure and were not used for this baseline.

```sh
bash -n infra/aws/setup-ec2.sh infra/aws/bootstrap.sh infra/aws/verify-host.sh
./infra/aws/setup-ec2.sh
```

The launcher checks the AWS account, official AMI, subnet, role trust/policies, ownership tags, and name collisions. It saves resource IDs incrementally in `state.json`. Rerunning with a recorded instance exits without creating another host; the EC2 client token also protects retries. Existing unrelated resources are never adopted or changed. Keep state and the generated `launch-request.json`. To intentionally create a separate future host, review/change names and client token in a separate configuration; do not simply delete state to bypass collision checks.

`bootstrap.sh` updates package indexes and installs only the base tools. `verify-host.sh` can be run through SSM Run Command (as during provisioning); it checks cloud-init completion, DNS, HTTPS, public GitHub access without cloning, Node/npm, CPU/RAM, free disk, IMDSv1 rejection, empty workspace, and absence of scanner/container commands and packages. Final EC2 instance, system, and EBS health checks all passed. Approximately 94 GiB was free.

AMI ID, Node version, and Node archive checksum are pinned. Ubuntu apt packages follow the repository versions available at provisioning time; the captured full package manifest records their exact installed versions. This is documented reproducibility, not a promise of bit-identical future rebuilds. Ubuntu/snap background updates can change a long-lived host, so collect metadata again with the eventual probe. Bootstrap metadata IMDS/EBS fields describe launch intent, independently verified in saved AWS API evidence.

Host files:

- `/home/ubuntu/research/` (empty, owned by ubuntu)
- `/home/ubuntu/ec2-environment-metadata.json` (non-secret experiment metadata)
- `/home/ubuntu/ec2-package-manifest.tsv` (all installed apt package versions)
- `/var/lib/cloud/instance/research-baseline-setup-complete` (setup marker)
- Normal `/usr/local` Node installation and cloud-init/SSM logs.

Repository files: `README.md`, `.gitignore`, `config.json`, `setup-ec2.sh`, `provision.py`, `bootstrap.sh`, and `verify-host.sh`. Generated local records: `state.json`, `launch-request.json`, and `evidence/` (gitignored). Evidence includes host metadata, verification output, pricing, regional availability, EC2 health/configuration, volume, SG, IAM profile/policies, and SSM/session results. Resource identifiers are bookkeeping and must not become classifier features. No credentials or session tokens are stored in those records.

## AWS resources created

| Resource | Identifier |
| --- | --- |
| EC2 instance | `i-068e4b9f4f532e9f7` |
| EBS root volume | `vol-02f480f3d2a065927` |
| Primary network interface | `eni-0a466d18d41d5ed5c` |
| Security group | `sg-06b02185a23e02db1` |
| IAM role | `npm-research-ec2-ssm-role` |
| IAM instance profile | `npm-research-ec2-ssm-profile` |

These resources have `Name=npm-research-ec2-dev`, `Project=package-environment-fingerprint`, `Environment=ec2-ubuntu-development`, `Purpose=research`, and `ManagedBy=research-experiment`. An automatically assigned public IPv4 address provides outbound Internet access; no Elastic IP, NAT gateway, load balancer, autoscaling group, extra VPC/subnet, S3 bucket, or redundant instance was created.

## Cost and lifecycle

On-demand public USD rates retrieved from the AWS Pricing API on 2026-10-14: m7i.xlarge in Sydney **$0.252/hour**, 100 GiB gp3 **$9.60/month** at $0.096/GB-month. Public IPv4 adds **$0.005/hour** ([AWS VPC pricing](https://aws.amazon.com/vpc/pricing/)). At 730 running hours this is approximately **$197.21/month** before transfer, taxes, credits, or discounts. Storage remains billable when stopped; the auto-assigned public IPv4 is released on stop. No extra gp3 IOPS/throughput were provisioned ([EBS pricing](https://aws.amazon.com/ebs/pricing/)).

The instance was left **running**, not terminated. Stop it between research sessions:

```sh
aws ec2 stop-instances --region ap-southeast-2 --instance-ids i-068e4b9f4f532e9f7
# Resume later:
aws ec2 start-instances --region ap-southeast-2 --instance-ids i-068e4b9f4f532e9f7
```

Do not install scanners until the plain development-host baseline has been captured. Before later scanner changes, decide whether to snapshot the baseline disk; this task deliberately created no additional backup charges.
