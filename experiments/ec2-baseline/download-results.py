#!/usr/bin/env python3
"""Retrieve completed baseline files via SSM in bounded, checksummed chunks."""
import base64,hashlib,io,json,pathlib,subprocess,tarfile,time
root=pathlib.Path('results/ec2/baseline');root.mkdir(parents=True,exist_ok=True)
def aws(*args):return json.loads(subprocess.check_output(['aws','--region','ap-southeast-2','--output','json',*args],text=True))
def run(script):
 c=aws('ssm','send-command','--instance-ids','i-068e4b9f4f532e9f7','--document-name','AWS-RunShellScript','--parameters',json.dumps({'commands':[script]}))['Command']['CommandId']
 for _ in range(60):
  time.sleep(2)
  try:r=aws('ssm','get-command-invocation','--instance-id','i-068e4b9f4f532e9f7','--command-id',c)
  except subprocess.CalledProcessError:continue
  if r['Status'] in ['Pending','InProgress','Delayed']:continue
  if r['Status']!='Success':raise RuntimeError(r['StandardErrorContent'])
  return r['StandardOutputContent']
 raise RuntimeError('Timed out: '+c)
script="""runuser -u ubuntu -- python3 - <<'PYREMOTE'
import hashlib,json,pathlib,tarfile
root=pathlib.Path('/home/ubuntu/research/results/ec2/baseline')
manifest=json.loads((root/'baseline-manifest.json').read_text());assert manifest['included_baseline_runs']==10
files=sorted(p for p in root.rglob('*') if p.is_file() and p.name!='ALL-SHA256SUMS')
(root/'ALL-SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(root))+'\\n' for p in files))
archive=root.parent/'baseline-results.tar.gz'
with tarfile.open(archive,'w:gz') as tf:
 for p in sorted(root.rglob('*')):
  if p.is_file():tf.add(p,arcname=str(p.relative_to(root)))
b=archive.read_bytes();print(json.dumps({'size':len(b),'sha256':hashlib.sha256(b).hexdigest()}))
PYREMOTE"""
info=json.loads(run(script));data=bytearray()
for start in range(0,info['size'],12000):
 text=run("python3 - <<'PYREMOTE'\nimport pathlib,base64\nb=pathlib.Path('/home/ubuntu/research/results/ec2/baseline-results.tar.gz').read_bytes()\nprint(base64.b64encode(b["+str(start)+":"+str(start+12000)+"]).decode())\nPYREMOTE")
 data.extend(base64.b64decode(text.strip(),validate=True))
assert len(data)==info['size'] and hashlib.sha256(data).hexdigest()==info['sha256']
archive=root.parent/'baseline-results.tar.gz'
if archive.exists():assert archive.read_bytes()==data,'Refusing to overwrite different archive'
else:archive.write_bytes(data)
with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as tf:
 for m in tf:
  assert m.isfile() and not pathlib.PurePosixPath(m.name).is_absolute() and '..' not in pathlib.PurePosixPath(m.name).parts
  target=root/m.name;b=tf.extractfile(m).read()
  if target.exists():assert target.read_bytes()==b,'Refusing to overwrite '+str(target)
  else:target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(b)
for line in (root/'ALL-SHA256SUMS').read_text().splitlines():
 h,p=line.split('  ',1);assert hashlib.sha256((root/p).read_bytes()).hexdigest()==h
(root.parent/'transfer-verification.json').write_text(json.dumps(info,indent=2)+'\n')
print('Downloaded',info['size'],'bytes; archive and all file checksums verified.')
