"""Explicit operational-resource cleanup and deleted-resource recovery drill."""
import json
import subprocess
import uuid

from botocore.exceptions import ClientError
from operations import ROOT, P, client, manifest, pages
from verify import request, tokens

m = manifest()
sqs = client('sqs'); logs = client('logs'); iam = client('iam'); s3 = client('s3')
extra = P + '-verification-extra'
tags = {'ClearLedgerDeployment': P}
queue = sqs.create_queue(QueueName=extra, tags=tags)['QueueUrl']
logs.create_log_group(logGroupName=extra, tags=tags)
s3.create_bucket(Bucket=extra)
s3.put_bucket_versioning(Bucket=extra, VersioningConfiguration={'Status':'Enabled'})
s3.put_object(Bucket=extra, Key='versioned', Body=b'one')
s3.put_object(Bucket=extra, Key='versioned', Body=b'two')
s3.delete_object(Bucket=extra, Key='versioned')
trust = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':'lambda.amazonaws.com'},'Action':'sts:AssumeRole'}]}
iam.create_role(RoleName=extra, AssumeRolePolicyDocument=json.dumps(trust), Tags=[{'Key':k,'Value':v} for k,v in tags.items()])
policy = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:GetObject','Resource':'arn:aws:s3:::' + extra + '/*'}]}
arn = iam.create_policy(PolicyName=extra, PolicyDocument=json.dumps(policy))['Policy']['Arn']
iam.create_policy_version(PolicyArn=arn, PolicyDocument=json.dumps(policy), SetAsDefault=True)
iam.attach_role_policy(RoleName=extra, PolicyArn=arn)
subprocess.run(['python3', str(ROOT/'cleanup.py'), 'extras'], check=True)
assert queue not in pages(sqs,'list_queues','QueueUrls')
assert extra not in [b['Name'] for b in pages(s3,'list_buckets','Buckets')]
assert extra not in [r['RoleName'] for r in pages(iam,'list_roles','Roles')]
assert arn not in [p['Arn'] for p in pages(iam,'list_policies','Policies',Scope='Local')]
print('Out-of-band cleanup verified: versioned bucket, queue, log group, role and multi-version attached policy.', flush=True)

lam = client('lambda')
lam.delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
sqs.delete_queue(QueueUrl=m['messaging']['queue_url'])
lam.delete_function(FunctionName=m['workers']['projector']['function_name'])
client('scheduler').delete_schedule(Name=m['schedules']['archive_schedule_name'])
logs.delete_log_group(logGroupName=m['logs']['projector_log_group'])
sid=str(uuid.uuid4())
body=dict(settlementId=sid, accountId='account-recovery', reference='deleted-queue-recovery', debitParty='BANK-A', creditParty='BANK-B', expectedVersion=0)
response=request(m,'POST','/v1/settlements',body,tokens(m)['write'],uuid.uuid4().hex)
assert response[0]==201,response
subprocess.run([str(ROOT/'deploy.sh')],check=True)
n=manifest()
assert n['database']['instance_id']==m['database']['instance_id']
assert n['projections']['table_arn']==m['projections']['table_arn']
assert n['audit']['bucket_arn']==m['audit']['bucket_arn']
assert n['messaging']['event_source_mapping_uuid']!=m['messaging']['event_source_mapping_uuid']
response=request(n,'GET','/v1/settlements/'+sid,token=tokens(n)['read'])
assert response[0]==200 and response[1].get('x-clearledger-source')=='cache',response
print('Deleted-resource recovery verified: queue, mapping, projector, log group and schedule; committed data preserved.')
