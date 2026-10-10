"""End-to-end recovery drill against the deployed local control/data planes.

Run explicitly: python3 /workspace/submission/verify.py
Creates a test ledger aggregate and intentionally drifts derived stores/resources.
"""
import datetime
import json
import subprocess
import time
import uuid

import requests
from operations import ROOT, PREFIX, client, connect, manifest, canonical_json


def require(response, code):
    assert response.status_code == code, (response.status_code, response.text)
    return response.json()


def main():
    m = manifest()
    tokens = {}
    for scope, c in m['auth']['clients'].items():
        tokens[scope] = require(requests.post(m['auth']['token_endpoint'], auth=(c['client_id'],c['client_secret']),
                                             data={'grant_type':'client_credentials','scope':c['scope']}, timeout=10), 200)['access_token']
    sid = str(uuid.uuid4())
    headers = {'Authorization':'Bearer '+tokens['write'], 'Idempotency-Key':'drill-create-'+sid, 'X-Correlation-Id':'recovery-drill'}
    create = dict(settlementId=sid,accountId='drill-account',reference='recovery-test',debitParty='bank-a',creditParty='bank-b',expectedVersion=0)
    endpoint = m['service_url']+'/v1/settlements'
    require(requests.post(endpoint,headers=headers,json=create,timeout=10),201)
    replay = require(requests.post(endpoint,headers=headers,json=create,timeout=10),200)
    assert replay['idempotentReplay'] is True
    require(requests.get(endpoint+'/'+sid, timeout=10),401)
    require(requests.get(endpoint+'/'+sid,headers={'Authorization':'Bearer '+tokens['admin']},timeout=10),403)
    require(requests.post(endpoint,headers={**headers,'Authorization':'Bearer '+tokens['read']},json=create,timeout=10),403)
    time.sleep(1)
    entry = dict(entryId=str(uuid.uuid4()),status='CLEARED',clearingStage='CLEARING@bank-b',memo='Clearing completed',
                 occurredAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),expectedVersion=1)
    headers['Idempotency-Key']='drill-entry-'+sid
    require(requests.post(endpoint+'/'+sid+'/entries',headers=headers,json=entry,timeout=10),202)
    backwards = {**entry, 'entryId':str(uuid.uuid4()),'expectedVersion':2,'status':'RESERVED',
                 'occurredAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
    headers['Idempotency-Key']='drill-invalid-'+sid
    require(requests.post(endpoint+'/'+sid+'/entries',headers=headers,json=backwards,timeout=10),400)
    read_headers = {'Authorization':'Bearer '+tokens['read']}
    deadline = time.monotonic()+30
    while True:
        response = requests.get(endpoint+'/'+sid,headers=read_headers,timeout=10)
        if response.status_code==200 and response.json()['version']==2:
            break
        assert time.monotonic()<deadline
        time.sleep(1)
    ledger = require(requests.get(endpoint+'/'+sid+'/ledger',headers=read_headers,timeout=10),200)
    assert [e['version'] for e in ledger['events']]==[1,2]
    lam = client('lambda')
    for worker in ('outbox_relay','audit_archiver'):
        r = lam.invoke(FunctionName=m['workers'][worker]['function_name'],Payload=b'{}')
        assert not r.get('FunctionError'), r['Payload'].read()
    durable = (m['database']['instance_id'],m['projections']['table_arn'],m['audit']['bucket_name'])
    # Corrupt both directions: stale attributes, missing events, and orphan keys.
    ddb = client('dynamodb')
    table = m['projections']['table_name']
    ddb.delete_item(TableName=table,Key={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'EVENT#00000001'}})
    ddb.put_item(TableName=table,Item={'PK':{'S':'SETTLEMENT#'+str(uuid.uuid4())},'SK':{'S':'STRAY'}})
    ddb.update_item(TableName=table,Key={'PK':{'S':'SETTLEMENT#'+sid},'SK':{'S':'STATE'}},
                    UpdateExpression='SET #v=:v, #r=:r',ExpressionAttributeNames={'#v':'version','#r':'reference'},
                    ExpressionAttributeValues={':v':{'N':'999'},':r':{'S':'CORRUPTED'}})
    import redis
    cache = redis.Redis(host=m['cache']['endpoint'],port=m['cache']['port'])
    cache.set('stray-key','bad')
    cache.set('clearledger:settlement:'+sid,'{}')
    s3 = client('s3')
    bucket = m['audit']['bucket_name']
    s3.put_object(Bucket=bucket,Key='stray-object',Body=b'bad')
    s3.put_object(Bucket=bucket,Key='stray-object',Body=b'bad-version')
    s3.delete_object(Bucket=bucket,Key='stray-object')
    items = s3.list_objects_v2(Bucket=bucket).get('Contents',[])
    if items:
        key = items[0]['Key']
        s3.put_object(Bucket=bucket,Key=key,Body=b'corrupted\n')
    # Repair schema, networking, IAM, schedules, logging, queues, and deleted workers.
    with connect() as db:
        db.execute('ALTER TABLE clearledger.events DISABLE TRIGGER event_guard')
        db.execute('ALTER TABLE clearledger.settlements DROP CONSTRAINT settlements_domain')
        db.execute('DROP INDEX clearledger.idx_clearledger_outbox_unpublished')
    iam = client('iam')
    role = PREFIX+'-ecs_task'
    iam.put_role_policy(RoleName=role,PolicyName=PREFIX+'-rogue',PolicyDocument=canonical_json({
        'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'*'}]}))
    ec2 = client('ec2')
    ec2.authorize_security_group_ingress(GroupId=m['network']['security_group_ids']['rds'],
                                       IpProtocol='tcp',FromPort=5432,ToPort=5432,CidrIp='0.0.0.0/0')
    ec2.authorize_security_group_egress(GroupId=m['network']['security_group_ids']['valkey'],
                                      IpPermissions=[{'IpProtocol':'-1','IpRanges':[{'CidrIp':'0.0.0.0/0'}]}])
    sqs = client('sqs')
    sqs.set_queue_attributes(QueueUrl=m['messaging']['dlq_url'],Attributes={'MessageRetentionPeriod':'60'})
    client('logs').put_retention_policy(logGroupName=m['logs']['api_log_group'],retentionInDays=1)
    lam.delete_event_source_mapping(UUID=m['messaging']['event_source_mapping_uuid'])
    sqs.delete_queue(QueueUrl=m['messaging']['queue_url'])
    lam.delete_function(FunctionName=m['workers']['audit_archiver']['function_name'])
    subprocess.run([str(ROOT/'deploy.sh')],check=True,timeout=720)
    repaired = manifest()
    assert durable == (repaired['database']['instance_id'],repaired['projections']['table_arn'],repaired['audit']['bucket_name'])
    response = requests.get(endpoint+'/'+sid,headers=read_headers,timeout=10)
    body = require(response,200)
    assert body['version']==2 and body['reference']=='recovery-test'
    assert response.headers['X-ClearLedger-Source']=='cache'
    assert cache.get('stray-key') is None
    assert iam.list_role_policies(RoleName=role)['PolicyNames']==[role+'-canonical']
    assert sqs.get_queue_attributes(QueueUrl=repaired['messaging']['dlq_url'],AttributeNames=['MessageRetentionPeriod'])['Attributes']['MessageRetentionPeriod']=='1209600'
    sg = ec2.describe_security_groups(GroupIds=[m['network']['security_group_ids']['valkey']])['SecurityGroups'][0]
    assert not sg['IpPermissionsEgress']
    assert client('logs').describe_log_groups(logGroupNamePrefix=m['logs']['api_log_group'])['logGroups'][0]['retentionInDays']==14
    with connect() as db:
        assert db.execute("SELECT count(*) AS n FROM pg_trigger WHERE tgrelid='clearledger.events'::regclass AND NOT tgisinternal AND tgenabled<>'O'").fetchone()['n']==0
        assert db.execute('SELECT count(*) AS n FROM clearledger.outbox WHERE published_at IS NULL OR archived_at IS NULL').fetchone()['n']==0
    print('PASS: OAuth isolation, writes/replay, status regression rejection, ordered ledger, worker invocation, drift/deletion repair, durable identity, and immediate cache reads.')


if __name__=='__main__':
    main()
