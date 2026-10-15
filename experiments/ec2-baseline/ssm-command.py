#!/usr/bin/env python3
"""Run a supplied shell file on the research host, saving full SSM command evidence."""
import argparse,json,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('script');p.add_argument('output');a=p.parse_args()
def aws(*args):
 return json.loads(subprocess.check_output(['aws','--region','ap-southeast-2','--output','json',*args],text=True))
c=aws('ssm','send-command','--instance-ids','i-068e4b9f4f532e9f7','--document-name','AWS-RunShellScript','--parameters',json.dumps({'commands':[pathlib.Path(a.script).read_text()],'executionTimeout':['600']}))['Command']['CommandId']
print('SSM command:',c,flush=True)
for _ in range(150):
 time.sleep(2)
 try:r=aws('ssm','get-command-invocation','--instance-id','i-068e4b9f4f532e9f7','--command-id',c)
 except subprocess.CalledProcessError:continue
 if r['Status'] in ['Pending','InProgress','Delayed']:continue
 pathlib.Path(a.output).write_text(json.dumps(r,indent=2)+'\n')
 print(r['StandardOutputContent']);print(r['StandardErrorContent'])
 raise SystemExit(0 if r['Status']=='Success' else 1)
raise SystemExit('Timed out; inspect command '+c)
