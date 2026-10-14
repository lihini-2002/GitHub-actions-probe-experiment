#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends git curl wget ca-certificates build-essential python3 jq unzip zip xz-utils
NODE_VERSION=22.23.3
NODE_SHA256=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
curl --fail --silent --show-error --location --retry 3 "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o node.tar.xz
printf '%s  node.tar.xz\n' "$NODE_SHA256" | sha256sum --check -
tar -xJf node.tar.xz -C /usr/local --strip-components=1 --no-same-owner
install -d -o ubuntu -g ubuntu -m 0755 /home/ubuntu/research
# Canonical Ubuntu EC2 images include SSM Agent. Do not add scanner dependencies.
if snap list amazon-ssm-agent >/dev/null 2>&1; then
  snap start amazon-ssm-agent
elif systemctl list-unit-files amazon-ssm-agent.service --no-legend | grep -q amazon-ssm-agent; then
  systemctl enable --now amazon-ssm-agent
else
  echo 'SSM Agent missing from AMI' >&2
  exit 1
fi
python3 - <<'PY'
import datetime, json, os, platform, subprocess, urllib.request
base='http://169.254.169.254/latest/'
token=urllib.request.urlopen(urllib.request.Request(base+'api/token',method='PUT',headers={'X-aws-ec2-metadata-token-ttl-seconds':'60'}),timeout=5).read().decode()
def meta(path):
    return urllib.request.urlopen(urllib.request.Request(base+path,headers={'X-aws-ec2-metadata-token':token}),timeout=5).read().decode()
def version(*args): return subprocess.check_output(args,text=True).strip()
doc=json.loads(meta('dynamic/instance-identity/document'))
osinfo=platform.freedesktop_os_release()
ram=int(next(line.split()[1] for line in open('/proc/meminfo') if line.startswith('MemTotal:')))
result={
 'region':doc['region'],'availability_zone':doc['availabilityZone'],
 'instance_id_bookkeeping_only':doc['instanceId'],'exclude_instance_id_from_classifier_features':True,
 'instance_type':doc['instanceType'],'architecture':platform.machine(),'ami_id':doc['imageId'],
 'ubuntu_version':osinfo['PRETTY_NAME'],'kernel_version':platform.release(),
 'vcpu_count':os.cpu_count(),'total_ram_kib':ram,'nominal_ram_gib':16,
 'ebs':{'volume_type':'gp3','size_gib':100,'encrypted':True,'source':'launch configuration; confirm with EC2 API'},
 'node_version':version('node','--version'),'npm_version':version('npm','--version'),
 'python_version':version('python3','--version'),'git_version':version('git','--version'),
 'instance_provisioning_timestamp':doc['pendingTime'],
 'setup_completed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'imds':{'endpoint':'enabled','tokens':'required','hop_limit':1},'remote_access':'Session Manager',
 'workspace':'/home/ubuntu/research','baseline_captured':False,
 'scanner_installation_performed':False,'docker_installation_performed':False,
 'node_archive_sha256':'df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de'
}
path='/home/ubuntu/ec2-environment-metadata.json'
with open(path,'w') as f: json.dump(result,f,indent=2); f.write('\n')
import pwd
u=pwd.getpwnam('ubuntu'); os.chown(path,u.pw_uid,u.pw_gid)
with open('/home/ubuntu/ec2-package-manifest.tsv','w') as f:
 subprocess.run(['dpkg-query','-W','-f=${Package}\t${Version}\n'],stdout=f,check=True)
os.chown('/home/ubuntu/ec2-package-manifest.tsv',u.pw_uid,u.pw_gid)
PY
touch /var/lib/cloud/instance/research-baseline-setup-complete
