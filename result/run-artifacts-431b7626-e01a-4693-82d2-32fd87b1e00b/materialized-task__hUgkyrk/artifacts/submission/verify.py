"""Optional end-to-end recovery drill; creates a settlement and intentional drift."""
import json
import urllib.request
import urllib.parse
import urllib.error
import uuid
import time
import datetime
import subprocess
import sys
import lifecycle as l

m=json.loads((l.ROOT/'manifest.json').read_text())
def token(scope):
    c=m['auth']['clients'][scope]
    req=urllib.request.Request(m['auth']['token_endpoint'],data=urllib.parse.urlencode(dict(grant_type='client_credentials',client_id=c['client_id'],client_secret=c['client_secret'],scope=c['scope'])).encode())
    return json.load(urllib.request.urlopen(req))['access_token']
tokens={s:token(s) for s in ['read','write','admin']}
def call(path,scope='read',body=None,key=None):
    headers={'Authorization':'Bearer '+tokens[scope],'X-Correlation-Id':'verify-correlation','Content-Type':'application/json'}
    if key: headers['Idempotency-Key']=key
    req=urllib.request.Request(m['service_url']+path,headers=headers,data=json.dumps(body).encode() if body is not None else None)
    try:
        r=urllib.request.urlopen(req)
        return r.status,json.load(r),dict(r.headers)
    except urllib.error.HTTPError as r:
        return r.code,json.load(r),dict(r.headers)

sid=str(uuid.uuid4())
body=dict(settlementId=sid,accountId='verify-account',reference='verify-reference',debitParty='bank-a',creditParty='bank-b',expectedVersion=0)
r=call('/v1/settlements','write',body,'verify-create-'+sid)
print('create',r);assert r[0]==201
assert call('/v1/settlements','write',body,'verify-create-'+sid)[0]==200
entry=dict(entryId=str(uuid.uuid4()),status='CLEARED',clearingStage='clearing',occurredAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),expectedVersion=1,memo='verified')
r=call('/v1/settlements/'+sid+'/entries','write',entry,'verify-entry-'+sid)
print('entry',r);assert r[0]==202
entry.update(entryId=str(uuid.uuid4()),status='RESERVED',expectedVersion=2,occurredAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
assert call('/v1/settlements/'+sid+'/entries','write',entry,'verify-invalid-'+sid)[0]==400
assert call('/v1/settlements/'+sid,'admin')[0]==403
for _ in range(30):
    r=call('/v1/settlements/'+sid)
    if r[0]==200 and r[1]['version']==2:break
    time.sleep(1)
print('projection',r);assert r[0]==200 and r[1]['version']==2
assert len(call('/v1/settlements/'+sid+'/ledger')[1]['events'])==2
conn=l.db_connect(m);conn.autocommit=True
l.invoke(l.client('lambda'),m['workers']['outbox_relay']['function_name'])
l.invoke(l.client('lambda'),m['workers']['audit_archiver']['function_name'])
print('worker lifecycle',l.query(conn,'SELECT seq,published_at,archived_at FROM clearledger.outbox ORDER BY seq'))
ddb=l.client('dynamodb');table=m['projections']['table_name']
actual=l.pages(ddb,'scan','Items',TableName=table)
print('actual event item',next(x for x in actual if x['SK']['S'].startswith('EVENT#')))
ddb.put_item(TableName=table,Item={'PK':{'S':'ORPHAN'},'SK':{'S':'STRAY'}})
ddb.update_item(TableName=table,Key={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'STATE'}},UpdateExpression='SET GSI1PK=:p',ExpressionAttributeValues={':p':{'S':'wrong'}})
redis=l.Redis(m['cache']['endpoint'],m['cache']['port']);redis.command('SET','stray','bad');redis.close()
s3=l.client('s3');s3.put_object(Bucket=m['audit']['bucket_name'],Key='junk',Body=b'bad')
iam=l.client('iam');role=m['iam']['ecs_task_role_arn'].rsplit('/',1)[-1]
iam.put_role_policy(RoleName=role,PolicyName='drift',PolicyDocument=json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]}))
l.client('logs').put_retention_policy(logGroupName=m['logs']['api_log_group'],retentionInDays=1)
l.client('sqs').set_queue_attributes(QueueUrl=m['messaging']['queue_url'],Attributes={'VisibilityTimeout':'99'})
subprocess.run(['/workspace/submission/deploy.sh'],check=True)
r=call('/v1/settlements/'+sid);print('post repair cache',r)
assert {k.lower():v for k,v in r[2].items()}['x-clearledger-source']=='cache'
assert 'drift' not in iam.list_role_policies(RoleName=role)['PolicyNames']
assert l.client('sqs').get_queue_attributes(QueueUrl=m['messaging']['queue_url'],AttributeNames=['VisibilityTimeout'])['Attributes']['VisibilityTimeout']=='3'
print('verification passed')
if '--deletions' in sys.argv:
    original_database=m['database']['instance_id']
    lam=l.client('lambda'); sqs=l.client('sqs'); scheduler=l.client('scheduler'); ec2=l.client('ec2')
    lam.delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
    sqs.delete_queue(QueueUrl=m['messaging']['queue_url'])
    sqs.delete_queue(QueueUrl=m['messaging']['dlq_url'])
    for field in ['outbox_schedule_name','archive_schedule_name']:
        scheduler.delete_schedule(Name=m['schedules'][field])
    env=lam.get_function_configuration(FunctionName=m['workers']['projector']['function_name'])['Environment']['Variables']
    l.worker_environment(lam,m['workers']['projector']['function_name'],{**env,'PROJECTION_TABLE':'missing-table'})
    for group in ['alb','rds','valkey']:
        ec2.authorize_security_group_egress(GroupId=m['network']['security_group_ids'][group],IpPermissions=[{'IpProtocol':'-1','IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
    subprocess.run(['/workspace/submission/deploy.sh'],check=True)
    repaired=json.loads((l.ROOT/'manifest.json').read_text())
    assert repaired['database']['instance_id']==original_database
    assert repaired['messaging']['event_source_mapping_uuid']!=m['messaging']['event_source_mapping_uuid']
    assert lam.get_event_source_mapping(UUID=repaired['messaging']['event_source_mapping_uuid'])['State']=='Enabled'
    assert lam.get_function_configuration(FunctionName=m['workers']['projector']['function_name'])['Environment']['Variables']['PROJECTION_TABLE']==table
    for group in ['rds','valkey']:
        assert not ec2.describe_security_groups(GroupIds=[m['network']['security_group_ids'][group]])['SecurityGroups'][0]['IpPermissionsEgress']
    assert call('/v1/settlements/'+sid)[1]['version']==2
    print('Deleted-resource and environment/egress recovery passed')
