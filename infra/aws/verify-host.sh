#!/bin/bash
set -euo pipefail
cloud-init status --wait
[ -f /var/lib/cloud/instance/research-baseline-setup-complete ]
[ "$(uname -m)" = x86_64 ]
[ "$(nproc)" -eq 4 ]
awk '/MemTotal/ {exit !($2 > 15000000)}' /proc/meminfo
[ "$(df --output=avail -B1 / | tail -1)" -gt 80000000000 ]
getent hosts github.com
curl --fail --silent --show-error --location --output /dev/null https://registry.npmjs.org/
runuser -u ubuntu -- git ls-remote https://github.com/nodejs/node.git HEAD
runuser -u ubuntu -- node -e 'if (process.arch !== "x64" || 2+2 !== 4) process.exit(1); console.log(process.version)'
runuser -u ubuntu -- npm --version
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 http://169.254.169.254/latest/meta-data/instance-id)" = 401 ]
for command in docker podman runsc latch packj fv8 pack-a-mal package-analysis; do
  if command -v "$command"; then echo "Unexpected scanner/container command: $command" >&2; exit 1; fi
done
! dpkg-query -W -f='${Package}\t${db:Status-Status}\n' | grep -E '^(docker-ce|docker.io|containerd|podman|runsc|gvisor|packj|latch|fv8|pack-a-mal)[[:space:]].*installed$'
[ -z "$(find /home/ubuntu/research -mindepth 1 -print -quit)" ]
[ ! -d /home/ubuntu/.aws ]
[ ! -f /home/ubuntu/.git-credentials ]
cat /home/ubuntu/ec2-environment-metadata.json
df -h /
free -h
snap list
npm list --global --depth=0
printf '\nBASELINE_VERIFICATION_PASSED\n'
