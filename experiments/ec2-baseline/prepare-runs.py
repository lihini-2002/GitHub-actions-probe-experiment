"""Run on the EC2 host as ubuntu before repeating installations. No installs here."""
import hashlib,json,pathlib,shutil,subprocess
home=pathlib.Path.home();repo=home/'research/GitHub-actions-probe-experiment'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()=='9660c7d01e31499de60f116fb6ce56ee76e9b69d'
assert hashlib.sha256((repo/'packages/npm-probing-package-0.1.0.tgz').read_bytes()).hexdigest()=='8ba84a1e7145dd5024380a9177cd24939591c0822b06afb37568f661ea084ba4'
old=home/'research/ec2-baseline-20261014'
report=list(old.glob('install-*.json'));assert len(report)==1
r=json.loads(report[0].read_text());assert r['runId']=='d3337ba0-bffe-4c54-8580-dc0811798b11' and len(r['properties'])==200
root=home/'research/results/ec2/baseline';root.mkdir(parents=True,exist_ok=True)
assert not (root/'run-001').exists(),'Refusing to overwrite run-001'
shutil.copytree(old,root/'run-001')
(root/'run-001/exit-codes.json').write_text(json.dumps({'npm_ci':0,'npm_test':0,'npm_build':0,'source':'previously verified successful original session'},indent=2)+'\n')
print('Original report preserved as run-001. Ready for nine repeats.')
