#!/usr/bin/env python3
"""Provision only the development baseline using AWS CLI; no SDK or IaC framework."""
import base64
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
C = json.loads((ROOT / 'config.json').read_text())
STATE = ROOT / 'state.json'
S = json.loads(STATE.read_text()) if STATE.exists() else {}
TAGS = [{'Key': k, 'Value': v} for k, v in C['tags'].items()]
POLICY = 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'

def aws(*args):
    p = subprocess.run(['aws', '--region', C['region'], '--output', 'json', '--no-cli-pager', *args],
                       text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError(p.stderr.strip())
    return json.loads(p.stdout) if p.stdout.strip() else {}

def save(key, value):
    S[key] = value
    STATE.write_text(json.dumps(S, indent=2) + '\n')

def owned(tags):
    actual = {t['Key']: t['Value'] for t in tags}
    return all(actual.get(k) == v for k, v in C['tags'].items())

def optional(*args):
    try:
        return aws(*args)
    except RuntimeError as e:
        if 'NoSuchEntity' in str(e):
            return None
        raise

identity = aws('sts', 'get-caller-identity')
assert identity['Account'] == C['account_id'], 'Wrong AWS account'
# Never silently launch a second host on rerun, even after termination.
if S.get('instance_id'):
    print(json.dumps(S, indent=2))
    print('Instance already recorded; inspect it rather than launching another.')
    raise SystemExit(0)
existing = aws('ec2', 'describe-instances', '--filters',
               'Name=tag:Name,Values=' + C['name'],
               'Name=instance-state-name,Values=pending,running,stopping,stopped')['Reservations']
assert not existing, 'A host with this name already exists; inspect before retrying'
ami = aws('ec2', 'describe-images', '--image-ids', C['ami_id'])['Images'][0]
assert ami['OwnerId'] == C['ami_owner'] and ami['Architecture'] == 'x86_64'
assert ami['State'] == 'available' and 'ubuntu-noble-24.04' in ami['Name']
subnet = aws('ec2', 'describe-subnets', '--subnet-ids', C['subnet_id'])['Subnets'][0]
assert subnet['VpcId'] == C['vpc_id'] and subnet['AvailabilityZone'] == C['availability_zone']

role = optional('iam', 'get-role', '--role-name', C['role_name'])
trust = {'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow',
         'Principal': {'Service': 'ec2.amazonaws.com'}, 'Action': 'sts:AssumeRole'}]}
if role is None:
    role = aws('iam', 'create-role', '--role-name', C['role_name'],
               '--assume-role-policy-document', json.dumps(trust), '--tags', json.dumps(TAGS))
assert owned(role['Role'].get('Tags', [])), 'Refusing unrelated IAM role'
assert role['Role']['AssumeRolePolicyDocument'] == trust, 'Unexpected trust policy'
save('role_arn', role['Role']['Arn'])
attached = aws('iam', 'list-attached-role-policies', '--role-name', C['role_name'])['AttachedPolicies']
assert all(p['PolicyArn'] == POLICY for p in attached), 'Unexpected role permissions'
assert not aws('iam', 'list-role-policies', '--role-name', C['role_name'])['PolicyNames']
if not attached:
    aws('iam', 'attach-role-policy', '--role-name', C['role_name'], '--policy-arn', POLICY)
profile = optional('iam', 'get-instance-profile', '--instance-profile-name', C['profile_name'])
if profile is None:
    profile = aws('iam', 'create-instance-profile', '--instance-profile-name', C['profile_name'],
                  '--tags', json.dumps(TAGS))
assert owned(profile['InstanceProfile'].get('Tags', [])), 'Refusing unrelated profile'
roles = profile['InstanceProfile'].get('Roles', [])
assert all(r['RoleName'] == C['role_name'] for r in roles)
if not roles:
    aws('iam', 'add-role-to-instance-profile', '--instance-profile-name', C['profile_name'],
        '--role-name', C['role_name'])
save('instance_profile_arn', profile['InstanceProfile']['Arn'])

groups = aws('ec2', 'describe-security-groups', '--filters',
              'Name=group-name,Values=' + C['name'] + '-ssm', 'Name=vpc-id,Values=' + C['vpc_id'])['SecurityGroups']
if groups:
    assert len(groups) == 1 and owned(groups[0].get('Tags', []))
    assert not groups[0]['IpPermissions'], 'Unexpected inbound permissions'
    sg = groups[0]['GroupId']
else:
    sg = aws('ec2', 'create-security-group', '--group-name', C['name'] + '-ssm',
             '--description', 'Research development host; Session Manager only; no inbound access',
             '--vpc-id', C['vpc_id'], '--tag-specifications',
             json.dumps([{'ResourceType': 'security-group', 'Tags': TAGS}]))['GroupId']
save('security_group_id', sg)
request = {
    'ImageId': C['ami_id'], 'InstanceType': C['instance_type'], 'MinCount': 1, 'MaxCount': 1,
    'ClientToken': C['client_token'], 'IamInstanceProfile': {'Name': C['profile_name']},
    'MetadataOptions': {'HttpEndpoint': 'enabled', 'HttpTokens': 'required',
                        'HttpPutResponseHopLimit': 1, 'InstanceMetadataTags': 'disabled'},
    'BlockDeviceMappings': [{'DeviceName': ami['RootDeviceName'], 'Ebs': {
        'VolumeType': 'gp3', 'VolumeSize': 100, 'Encrypted': True,
        'Iops': 3000, 'Throughput': 125, 'DeleteOnTermination': True}}],
    'NetworkInterfaces': [{'DeviceIndex': 0, 'SubnetId': C['subnet_id'],
                           'Groups': [sg], 'AssociatePublicIpAddress': True, 'DeleteOnTermination': True}],
    'TagSpecifications': [{'ResourceType': kind, 'Tags': TAGS}
                          for kind in ['instance', 'volume', 'network-interface']],
    'UserData': base64.b64encode((ROOT / 'bootstrap.sh').read_bytes()).decode(),
    'Monitoring': {'Enabled': False}, 'InstanceInitiatedShutdownBehavior': 'stop'
}
(ROOT / 'launch-request.json').write_text(json.dumps(request, indent=2) + '\n')
# Allow propagation; retry only the known instance-profile propagation error.
for attempt in range(6):
    try:
        response = aws('ec2', 'run-instances', '--cli-input-json', json.dumps(request))
        break
    except RuntimeError as e:
        if 'Invalid IAM Instance Profile' not in str(e) or attempt == 5:
            raise
        time.sleep(10)
instance = response['Instances'][0]
save('instance_id', instance['InstanceId'])
save('launch_time', instance['LaunchTime'])
print(json.dumps(S, indent=2))
