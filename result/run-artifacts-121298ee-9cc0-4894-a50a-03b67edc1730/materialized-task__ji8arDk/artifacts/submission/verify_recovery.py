"""Opt-in recovery drill: python3 verify_recovery.py. Alters only this deployment."""
import json, pathlib, subprocess
import boto3, psycopg2, redis, requests
ROOT=pathlib.Path(__file__).resolve().parent
C=json.loads(pathlib.Path('/workspace/config/config.json').read_text())
M=json.loads((ROOT/'manifest.json').read_text())
d=M['database']
db=psycopg2.connect(host=d['endpoint'],port=d['port'],dbname=d['db_name'],user=d['username'],password=C['db_password'])
db.autocommit=True
cur=db.cursor()
cur.execute('select count(*) from clearledger.events'); original=cur.fetchone()[0]
ddb=boto3.client('dynamodb'); table=M['projections']['table_name']
ddb.put_item(TableName=table,Item={'PK':{'S':'SETTLEMENT#orphan'},'SK':{'S':'STATE'},'version':{'N':'999'}})
cur.execute('select settlement_id from clearledger.settlements limit 1'); sid=str(cur.fetchone()[0])
ddb.put_item(TableName=table,Item={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'STATE'},'version':{'N':'999'},'extra':{'S':'poison'}})
r=redis.Redis(host=M['cache']['endpoint'],port=M['cache']['port'])
r.set('stray-key','garbage'); r.set('clearledger:settlement:'+sid,'garbage'); r.set('clearledger:settlement:orphan','garbage')
s3=boto3.client('s3'); bucket=M['audit']['bucket_name']
keys=s3.list_objects_v2(Bucket=bucket)['Contents']
s3.put_object(Bucket=bucket,Key=keys[0]['Key'],Body=b'corrupted\n')
s3.put_object(Bucket=bucket,Key='outside-audit/rogue',Body=b'rogue')
cur.execute('alter table clearledger.settlements drop constraint settlements_fields')
cur.execute('alter table clearledger.settlements add constraint settlements_fields check(true)')
cur.execute('alter table clearledger.events disable trigger user')
cur.execute('drop index clearledger.idx_clearledger_entry_id')
cur.execute('drop index clearledger.idx_clearledger_outbox_unarchived')
kms=boto3.client('kms'); kms.disable_key(KeyId=M['kms']['projection_arn'])
iam=boto3.client('iam'); role=M['iam']['projector_role_arn'].split('/')[-1]
iam.put_role_policy(RoleName=role,PolicyName=C['resource_prefix']+'-rogue',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'*','Resource':'*'}]}))
ec2=boto3.client('ec2'); ec2.authorize_security_group_ingress(GroupId=M['network']['security_group_ids']['ecs'],IpPermissions=[{'IpProtocol':'tcp','FromPort':22,'ToPort':22,'IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
lambda_=boto3.client('lambda'); lambda_.delete_event_source_mapping(UUID=M['messaging']['event_source_mapping_uuid'])
sqs=boto3.client('sqs'); sqs.delete_queue(QueueUrl=M['messaging']['queue_url'])
print('Injected database, security, IAM, KMS, queue, mapping, projection, cache and archive drift',flush=True)
subprocess.run([str(ROOT/'deploy.sh')],check=True)
N=json.loads((ROOT/'manifest.json').read_text())
assert N['database']['instance_arn']==M['database']['instance_arn']
assert N['projections']['table_arn']==M['projections']['table_arn']
assert N['audit']['bucket_name']==M['audit']['bucket_name']
cur.execute('select count(*) from clearledger.events'); assert cur.fetchone()[0]==original
cur.execute("select count(*) from pg_trigger where tgrelid='clearledger.events'::regclass and not tgisinternal and tgenabled <> 'O'"); assert cur.fetchone()[0]==0
assert kms.describe_key(KeyId=N['kms']['projection_arn'])['KeyMetadata']['KeyState']=='Enabled'
assert iam.list_role_policies(RoleName=role)['PolicyNames']==[role+'-canonical']
assert not ddb.get_item(TableName=table,Key={'PK':{'S':'SETTLEMENT#orphan'},'SK':{'S':'STATE'}}).get('Item')
assert not r.exists('stray-key') and not r.exists('clearledger:settlement:orphan')
for page in s3.get_paginator('list_object_versions').paginate(Bucket=bucket):
 assert not page.get('DeleteMarkers')
 assert all(v['IsLatest'] and v['Key'].startswith('ledger-audit/batch-') for v in page.get('Versions',[]))
read=N['auth']['clients']['read']; token=requests.post(N['auth']['token_endpoint'],data={'grant_type':'client_credentials','client_id':read['client_id'],'client_secret':read['client_secret'],'scope':read['scope']}).json()['access_token']
resp=requests.get(N['service_url']+'/v1/settlements/'+sid,headers={'Authorization':'Bearer '+token})
assert resp.status_code==200 and resp.headers['X-ClearLedger-Source']=='cache', (resp.status_code,resp.text,resp.headers)
assert resp.json()['lastMemo']=='Settlement initiated'
print('Full recovery drill passed; durable resource identities and committed events preserved')
