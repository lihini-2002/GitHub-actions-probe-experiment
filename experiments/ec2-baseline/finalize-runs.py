"""Validate and organize already captured runs on EC2 as ubuntu; never invokes a probe."""
import collections,csv,datetime,hashlib,io,json,pathlib,platform,subprocess,tarfile
home=pathlib.Path.home();root=home/'research/results/ec2/baseline';repo=home/'research/GitHub-actions-probe-experiment'
def cmd(*args):return subprocess.check_output(args,text=True,cwd=repo).strip()
def write(p,obj):p.write_text(json.dumps(obj,indent=2,ensure_ascii=False)+'\n')
initial=json.loads((home/'ec2-environment-metadata.json').read_text())
assert platform.release()==initial['kernel_version']
assert platform.freedesktop_os_release()['PRETTY_NAME']==initial['ubuntu_version']
assert cmd('node','--version')==initial['node_version'] and cmd('npm','--version')==initial['npm_version']
commit=cmd('git','rev-parse','HEAD');assert commit=='9660c7d01e31499de60f116fb6ce56ee76e9b69d'
probe=repo/'packages/npm-probing-package-0.1.0.tgz';digest=hashlib.sha256(probe.read_bytes()).hexdigest()
assert digest=='8ba84a1e7145dd5024380a9177cd24939591c0822b06afb37568f661ea084ba4'
with tarfile.open(probe) as tf:
 catalog={x for row in csv.reader(io.StringIO(tf.extractfile('package/catalog/npm-install-environment-properties.csv').read().decode())) for x in row}
valid={'ok','absent','unsupported','permission_denied','timeout','error','truncated','disabled'}
entries=[];reports=[];report_numbers=[];seen=set()
for number in range(1,12):
 p=root/f'run-{number:03d}';files=list(p.glob('install-*.json'));reasons=[];r=None
 codes=json.loads((p/'exit-codes.json').read_text())
 if any(codes.get(k)!=0 for k in ['npm_ci','npm_test','npm_build']):reasons.append('nonzero command exit')
 try:
  assert len(files)==1 and files[0].stat().st_size>0
  r=json.loads(files[0].read_text());assert r['schemaVersion']==2 and r['phase']=='postinstall'
  assert r['package']=={'name':'npm-probing-package','version':'0.1.0'}
  assert len(r['properties'])==200 and set(r['properties']).issubset(catalog)
  assert r['runId'] not in seen
  for value in r['properties'].values():assert set(value)=={'value','status'} and value['status'] in valid
  seen.add(r['runId'])
 except (AssertionError,KeyError,ValueError) as e:reasons.append('invalid/missing/duplicate probe report')
 ctx=(p/'context.txt').read_text()
 assert commit in ctx and digest in ctx and initial['node_version'] in ctx and initial['npm_version'] in ctx and initial['kernel_version'] in ctx
 m={'environment':'aws-ec2-ubuntu-development-host','run_number':number,'run_id':r.get('runId') if r else None,
 'timestamp':r.get('collectedAt') if r else ctx.splitlines()[0],
 'instance_id':initial['instance_id_bookkeeping_only'],'ami_id':initial['ami_id'],'instance_type':initial['instance_type'],
 'region':initial['region'],'availability_zone':initial['availability_zone'],
 'ubuntu_version':initial['ubuntu_version'],'kernel_version':initial['kernel_version'],
 'node_version':initial['node_version'],'npm_version':initial['npm_version'],'probe_version':'0.1.0','probe_sha256':digest,
 'repository_commit':commit,'installation_command':'npm ci','user':'ubuntu','access_method':'interactive Session Manager -> sudo -iu ubuntu',
 'stdout_stderr_capture':'tee; npm lifecycle uses default background execution',
 'reused_original_run':number==1,'included_in_matched_baseline':number>1,'exclusion_reason':'Automatic apt upgrades occurred between this original run and the repeats' if number==1 else None,'success':not reasons,'failure_reasons':reasons,'exit_codes':codes,
 'lifecycle_evidence':'unique schema-2 postinstall report produced by installed package',
 'metadata_not_classifier_features':True,
 'status_counts':dict(collections.Counter(v['status'] for v in r['properties'].values())) if r else {}}
 # New metadata filename preserves the original run-001 run-metadata.json and checksums.
 write(p/'experiment-metadata.json',m)
 entries.append({'run_number':number,'directory':p.name,'report':str(files[0].relative_to(root)) if len(files)==1 else None,'metadata':f'{p.name}/experiment-metadata.json','run_id':m['run_id'],'timestamp':m['timestamp'],'success':m['success'],'included_in_matched_baseline':number>1})
 if not reasons and number>1:reports.append(r);report_numbers.append(number)
manifest={'environment':'aws-ec2-ubuntu-development-host','attempted_runs':len(entries),'successful_runs':sum(e['success'] for e in entries),'included_baseline_runs':len(reports),
 'new_runs_this_task':10,'reused_successful_runs':0,'excluded_run_numbers':[1],'probe_version':'0.1.0','probe_sha256':digest,'repository_commit':commit,
 'instance_configuration':initial,'node_version':initial['node_version'],'npm_version':initial['npm_version'],
 'first_collected_at':entries[1]['timestamp'],'last_collected_at':entries[-1]['timestamp'],
 'organized_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'runs':entries,
 'metadata_not_classifier_features':True,'notes':['Original provisioning snapshot is historical; baseline_captured=false there predates this collection.', 'Warm-cache repeats; no OS reinstall, cache cleaning, instrumentation, or scanner installation. Run 011 follows the provisional AMI consistency reboot.', 'Original run 001 excluded: ten apt package updates at 06:08-06:09 UTC occurred after its capture. Included run numbers 002-011 share the post-update software state.']}
write(root/'baseline-manifest.json',manifest)
assert len(reports)==10,'Failed runs preserved; do not count them as successful'
keys=set(reports[0]['properties']);assert all(set(r['properties'])==keys for r in reports)
stable=[];changed=[];occasional=[];nonok=[]
for key in sorted(keys):
 vals=[r['properties'][key] for r in reports];statuses=[v['status'] for v in vals]
 observations=[]
 for i,v in enumerate(vals):
  existing=next((o for o in observations if o['observation']==v),None)
  if existing:existing['runs'].append(report_numbers[i])
  else:observations.append({'observation':v,'runs':[report_numbers[i]]})
 if len(observations)==1:stable.append(key)
 else:changed.append({'field':key,'observations':observations})
 if len(set(statuses))>1 and any(s!='ok' for s in statuses):occasional.append({'field':key,'statuses_by_run':statuses})
 if all(s!='ok' for s in statuses):nonok.append({'field':key,'statuses_by_run':statuses})
write(root/'stability.json',{'comparison':'Exact value and status equality across the 200 property entries; bookkeeping excluded','run_count':10,'included_run_numbers':report_numbers,'identical_field_count':len(stable),'identical_fields':stable,'changing_field_count':len(changed),'changing_fields':changed,'occasionally_unavailable_or_partial':occasional,'consistently_non_ok':nonok,'report_fields_outside_features':['runId','collectedAt'],'no_features_removed':True})
with (root/'base-package-manifest.tsv').open('w') as f:subprocess.run(['dpkg-query','-W','-f=${Package}\t${Version}\n'],stdout=f,check=True)
print(json.dumps({'attempted':len(entries),'successful':sum(e['success'] for e in entries),'included':len(reports),'identical':len(stable),'changed':[x['field'] for x in changed],'occasional':occasional},indent=2))
